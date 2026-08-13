# Tests

Unit tests and integration tests for TumorSPACE_AWS.

## Test Scripts

| Script | What it tests | Run time |
|--------|--------------|----------|
| `acquisition/test_installation.sh` | GEO acquisition tool installation | ~1 min |
| `acquisition/test_*.py` | Acquisition unit tests (benchmark, classify, harmonize, validate, search cache) — offline, no network | ~30 sec |
| `bayesspace/test_bayesspace.sh` | BayesSpace container ≡ native (md5 match) + `cluster_plot.png` generated | ~5 min |
| `clean_container_rebuild.sh` | Full clean-room container build from a fresh clone (merge gate) | ~45 min |

## Usage

```bash
# GEO acquisition tool installation test
bash tests/acquisition/test_installation.sh

# Acquisition unit tests (requires pytest)
pytest tests/acquisition/

# Fast BayesSpace smoke test
bash tests/bayesspace/test_bayesspace.sh

# Full clean rebuild (run before merging to master)
bash tests/clean_container_rebuild.sh
```
