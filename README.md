# SimpleLife App

A small FastAPI life-insurance quote demo. Part of the SimpleLife agentic SDLC/STLC demo workspace.

Sibling repos:
- [simplelife-tests](../simplelife-tests) — Playwright + pytest automation suite that drives this app
- [simplelife-agents](../simplelife-agents) — Claude agent orchestration that builds and tests this app end-to-end

## Pages

| Route | Method | Purpose |
|---|---|---|
| `/` | GET | Quote form |
| `/quote` | POST | Form submission → quote result |
| `/about` | GET | About page |
| `/api/quote` | GET | JSON quote endpoint (used by tests + agents) |
| `/health` | GET | Health check |

## Run locally

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .
python -m webapp.main
# open http://127.0.0.1:8000/
```

Environment variables (all optional):

| Var | Default | Purpose |
|---|---|---|
| `WEBAPP_HOST` | `127.0.0.1` | bind address |
| `WEBAPP_PORT` | `8000` | bind port |

## Quote calculation

See [webapp/quote_engine.py](webapp/quote_engine.py). Deterministic illustrative formula:
- Base rate per $1,000 scales with age
- Smoker × 1.75
- Health excellent 0.85× / good 1.0× / average 1.25× / poor 1.75×
- Long-term policies add a small per-year premium

Not actuarially sound — demo only.

## Stable test hooks

The templates expose `data-testid` attributes on every interactive element (`full_name`, `age`, `gender`, `smoker`, `health`, `coverage_amount`, `term_years`, `submit-quote`, `quote-result`, `monthly-premium`, etc.). The [simplelife-tests](../simplelife-tests) repo depends on these.

## CI

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs a smoke route check on every PR via FastAPI's TestClient — no browser needed.
