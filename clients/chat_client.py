"""Standalone chat client: you own the orchestration.

This is the alternative to driving the toolkit through Claude Desktop. It spawns
the MCP server over stdio, lists its tools, and runs an Anthropic message loop
that lets the model call those tools and interpret the results. The value of the
custom client (versus Claude Desktop) is that the system prompt is yours: the
methodological guardrails for interpretation live here, on top of the per-tool
guardrails that live in the server.

Usage:
    export ANTHROPIC_API_KEY=sk-...
    python src/chat_client.py
    # optional: ANTHROPIC_MODEL=claude-opus-4-8 python src/chat_client.py
    # alternate backend (Gemini): LLM_PROVIDER=google GEMINI_API_KEY=... python src/chat_client.py

The loop is intentionally small and readable so it is easy to extend (swap the
model or provider, add MCP servers, change the prompt). The model vendor is a seam:
see providers.py. It is not hardened for production.
"""

from __future__ import annotations

import asyncio
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from providers import get_provider, normalize_tool_result
from system_prompt import build_system_prompt

MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS") or os.environ.get("ANTHROPIC_MAX_TOKENS", "8192"))


def _select_provider():
    """Pick the LLM backend from the environment (default: Anthropic/Claude)."""
    name = os.environ.get("LLM_PROVIDER", "anthropic").lower()
    model = (os.environ.get("GEMINI_MODEL") or os.environ.get("GOOGLE_MODEL")
             if name in ("google", "gemini") else os.environ.get("ANTHROPIC_MODEL"))
    return get_provider(name, model, MAX_TOKENS)


async def run() -> None:
    provider = _select_provider()  # validates the key for the chosen backend

    server = StdioServerParameters(command=sys.executable, args=["src/McpServer/mcp_server.py"])

    async with stdio_client(server) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            mcp_tools = (await session.list_tools()).tools
            provider.prepare_tools(mcp_tools)
            system_prompt = build_system_prompt()
            print(f"Connected. {len(mcp_tools)} tools available. "
                  f"Provider: {provider.name}, model: {provider.model}")
            print("Ask about a study (say 'list the studies' to see what's available). Ctrl-C to quit.\n")

            while True:
                try:
                    user = input("you> ").strip()
                except (EOFError, KeyboardInterrupt):
                    print("\nbye")
                    return
                if not user:
                    continue
                provider.add_user(user)

                # agentic loop: keep going while the model requests tools
                while True:
                    step = provider.step(system_prompt)
                    if step["text"]:
                        print(f"\n{provider.name}> {step['text']}\n")
                    if not step["tool_calls"]:
                        break

                    results = []
                    for tc in step["tool_calls"]:
                        print(f"  [calling {tc['name']} {tc['input']}]")
                        out = await session.call_tool(tc["name"], tc["input"])
                        results.append({"id": tc["id"], "name": tc["name"],
                                        "blocks": normalize_tool_result(out)})
                    provider.add_tool_results(results)


if __name__ == "__main__":
    asyncio.run(run())
