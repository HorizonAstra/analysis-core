const form = document.getElementById("loginForm");
const err = document.getElementById("loginError");
const btn = document.getElementById("loginBtn");

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  err.textContent = "";
  btn.disabled = true;
  const username = document.getElementById("username").value.trim();
  const password = document.getElementById("password").value;
  try {
    const r = await fetch("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password }),
    });
    if (r.ok) {
      window.location.href = "/";
    } else {
      const d = await r.json().catch(() => ({}));
      err.textContent = d.error || "Incorrect email or password.";
      btn.disabled = false;
    }
  } catch {
    err.textContent = "Couldn’t reach the server.";
    btn.disabled = false;
  }
});
