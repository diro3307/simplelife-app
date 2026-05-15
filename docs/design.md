# SimpleLife — Detailed Design & Requirements

**Document status:** Reverse-engineered from the codebase at commit `054b4ed` on branch `main` (2026-05-14).
**Scope:** Phase-1 demo of the SimpleLife life-insurance quote app. Subject to change as Phase-2 design assets land in [`designs/`](../designs/).

---

## 1. Purpose & Context

SimpleLife is a small FastAPI web application that produces an **illustrative** life-insurance premium quote from a short questionnaire. It is part of a three-repo demonstration of agentic SDLC/STLC:

| Repo | Role |
|---|---|
| **simplelife-app** (this repo) | The system under development — the runtime application. |
| `simplelife-tests` | Playwright + pytest automation that drives this app. |
| `simplelife-agents` | Claude agent orchestration that builds, modifies, and tests this app end-to-end. |

Because the app exists primarily to be **driven by agents and tests**, two non-obvious goals shape the design:

1. **Deterministic, easily pinnable output** — the premium formula must be stable so tests can assert exact values.
2. **Stable test hooks** — every interactive UI element exposes a `data-testid` attribute the sibling test repo depends on.

This document captures the as-built design and the requirements implied by that design.

---

## 2. Functional Requirements

### 2.1 User-facing functionality

| ID | Requirement |
|---|---|
| **FR-1** | A visitor can open a home page and see a quote-request form. |
| **FR-2** | A visitor can submit the form and receive a calculated illustrative premium on a result page. |
| **FR-3** | A visitor can navigate to an "About" page that explains how the quote is calculated. |
| **FR-4** | Invalid form submissions re-render the form with an error message rather than crashing or 5xx-ing. |
| **FR-5** | A visitor can return to the form from the result page to request a new quote. |

### 2.2 Programmatic / integration functionality

| ID | Requirement |
|---|---|
| **FR-6** | A JSON endpoint (`GET /api/quote`) returns the same computed quote for use by tests and agents. |
| **FR-7** | A health endpoint (`GET /health`) returns a 200 with a static OK payload for liveness checks and CI. |
| **FR-8** | All interactive form controls and all result-page values expose `data-testid` attributes so external test suites can target them without relying on visual layout. |

### 2.3 Domain rules — quote calculation

The formula is intentionally simple and **must remain deterministic** ([`webapp/quote_engine.py`](../webapp/quote_engine.py)):

| ID | Rule |
|---|---|
| **DR-1** | Base rate per $1,000 of coverage = `0.50 + (age - 18) * 0.04` USD. |
| **DR-2** | Smoker multiplier = `1.75` if smoker == "yes" else `1.00`. |
| **DR-3** | Health multiplier ∈ `{excellent: 0.85, good: 1.00, average: 1.25, poor: 1.75}`. |
| **DR-4** | Term multiplier = `1.00 + (term_years - 10) * 0.03`. |
| **DR-5** | `risk_score = round(smoker_mult * health_mult * term_mult, 3)`. |
| **DR-6** | `annual_premium = (coverage_amount / 1000) * base_rate_per_1000 * risk_score`, rounded to 2 dp. |
| **DR-7** | `monthly_premium = annual_premium / 12`, rounded to 2 dp. |

> **Worked example** — age 30, non-smoker, good health, $100,000 coverage, 20-year term:
> - base = `0.50 + 12*0.04 = 0.98`
> - risk = `1.00 * 1.00 * 1.30 = 1.30`
> - annual = `100 * 0.98 * 1.30 = 127.40`
> - monthly = `10.62`

### 2.4 Validation rules

Applied identically on both the HTML form path and the JSON API path ([`webapp/main.py:32`](../webapp/main.py#L32) and [`webapp/quote_engine.py:44`](../webapp/quote_engine.py#L44)):

| Field | Constraint |
|---|---|
| `full_name` | non-empty after strip, length 1–120 |
| `age` | integer, 18 ≤ age ≤ 75 |
| `gender` | one of `male`, `female`, `other` |
| `smoker` | one of `yes`, `no` |
| `health` | one of `excellent`, `good`, `average`, `poor` |
| `coverage_amount` | numeric, 10,000 ≤ x ≤ 5,000,000 |
| `term_years` | integer in `{10, 15, 20, 25, 30}` |

Validation occurs in two layers — Pydantic first (`QuoteRequest`), then a defensive re-check inside the engine (`_validate`). The engine layer is what guarantees the same rules apply whether the caller is the form, the API, or a future internal caller.

---

## 3. Non-Functional Requirements

| ID | Requirement | Rationale / source |
|---|---|---|
| **NFR-1** | Python ≥ 3.10 ([`pyproject.toml`](../pyproject.toml)). CI targets 3.12 ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)). |
| **NFR-2** | App is a single-process ASGI service; no database, no external calls — fully self-contained. |
| **NFR-3** | Quote calculation is pure and deterministic — same input always produces same output. |
| **NFR-4** | All HTML pages render server-side via Jinja2 — no client-side JavaScript framework required. |
| **NFR-5** | Configuration via environment variables only — `WEBAPP_HOST`, `WEBAPP_PORT` (both optional, defaults `127.0.0.1:8000`). |
| **NFR-6** | `.env` and `.env.local` are loaded via `python-dotenv` but must never be committed (enforced by [`.gitignore`](../.gitignore)). |
| **NFR-7** | CI must run on every PR and push to `main`, exercising at least: `/health`, `/`, `/about`, and a representative `/api/quote` call. |
| **NFR-8** | Lint (`ruff`) is advisory in Phase 1 (`|| true` in the workflow). It is **not** a merge gate. |
| **NFR-9** | Test hooks (`data-testid`) on form fields, the submit button, the result section, and every result row are part of the public contract with the sibling test repo and must not be removed without coordination. |

---

## 4. System Architecture

### 4.1 High-level component view

```
                           ┌──────────────────────────┐
   Browser (HTML/CSS)  ──► │  FastAPI app (ASGI)       │
   simplelife-tests    ──► │  webapp/main.py           │
   simplelife-agents   ──► │   ├─ Routes               │
                           │   ├─ Pydantic QuoteRequest │
                           │   ├─ Jinja2 templates      │
                           │   └─ Static files          │
                           │                            │
                           │  webapp/quote_engine.py    │
                           │   ├─ QuoteInput / Result   │
                           │   └─ calculate_quote()     │
                           └──────────────────────────┘
                                       │
                                  (no I/O)
```

There is no database, cache, message bus, or external API. The entire system is a single ASGI process.

### 4.2 Module map

| Module | Responsibility |
|---|---|
| [`webapp/__init__.py`](../webapp/__init__.py) | Package marker (empty). |
| [`webapp/main.py`](../webapp/main.py) | FastAPI app construction, route handlers, request DTO (`QuoteRequest`), uvicorn launcher. |
| [`webapp/quote_engine.py`](../webapp/quote_engine.py) | Pure domain logic: input/result dataclasses, validation, premium calculation. |
| [`webapp/templates/`](../webapp/templates/) | Jinja2 templates — `base.html` (layout), `index.html` (form), `quote.html` (result), `about.html`. |
| [`webapp/static/`](../webapp/static/) | `styles.css` — single stylesheet, no JS. |

### 4.3 Dependency boundaries

`quote_engine.py` imports only the standard library. It has no awareness of FastAPI, Pydantic, or HTTP. This makes it independently unit-testable and reusable from any future caller (a CLI, a different framework, a background job).

`main.py` depends on the engine but the reverse is forbidden. Pydantic `QuoteRequest` validates HTTP/form input and converts to the framework-free `QuoteInput` dataclass via `to_engine_input()`.

---

## 5. Detailed Design

### 5.1 Routes

| Method | Path | Handler | Response | Notes |
|---|---|---|---|---|
| GET | `/` | `index` | `index.html` (200) | Renders the empty form. |
| POST | `/quote` | `quote_form` | `quote.html` (200) or `index.html` (400) | Form-encoded submission; on validation error, re-renders the form with an `error` template variable. |
| GET | `/about` | `about` | `about.html` (200) | Static informational page. |
| GET | `/api/quote` | `api_quote` | JSON (200) or HTTP 400 with `detail` | Query-string parameters mirror the form fields. |
| GET | `/health` | `health_check` | `{"status": "ok"}` (200) | Liveness probe; used by CI smoke. |

### 5.2 Data model

**`QuoteRequest`** (Pydantic, [`main.py:32`](../webapp/main.py#L32)) — the HTTP-facing DTO. Performs type coercion and regex/range validation.

**`QuoteInput`** (frozen `dataclass`, [`quote_engine.py:17`](../webapp/quote_engine.py#L17)) — the engine-facing immutable input. Field types use `Literal[...]` so static analysis catches invalid enum values.

**`QuoteResult`** (frozen `dataclass`, [`quote_engine.py:28`](../webapp/quote_engine.py#L28)) — fields: `monthly_premium`, `annual_premium`, `coverage_amount`, `term_years`, `risk_score`.

### 5.3 `/api/quote` response contract

```json
{
  "applicant": {
    "full_name": "string",
    "age": 30,
    "gender": "male|female|other",
    "smoker": "yes|no",
    "health": "excellent|good|average|poor",
    "coverage_amount": 100000.0,
    "term_years": 20
  },
  "monthly_premium": 10.62,
  "annual_premium": 127.40,
  "coverage_amount": 100000.0,
  "term_years": 20,
  "risk_score": 1.3
}
```

Validation failures return HTTP 400 with `{"detail": "<message>"}`.

### 5.4 Request flow — form submission

```
Browser  ──POST /quote──►  quote_form()
                              │
                              ├─ QuoteRequest(...)        ── Pydantic validation
                              │     └─ ValidationError ──► render index.html (400) + error
                              │
                              ├─ req.to_engine_input()
                              │
                              ├─ calculate_quote(input)   ── domain validation
                              │     └─ ValueError ───────► render index.html (400) + error
                              │
                              └─ render quote.html (200)  with applicant + result
```

### 5.5 UI design

- **Layout** — single `base.html` provides a header (brand + nav), `<main class="container">`, and a footer. All pages extend it.
- **Form** ([`index.html`](../webapp/templates/index.html)) — server-rendered, native HTML controls. HTML5 constraints (`min`/`max`/`required`/`maxlength`) provide first-line client-side validation; server-side Pydantic is the authoritative gate.
- **Result** ([`quote.html`](../webapp/templates/quote.html)) — read-only card listing monthly premium, annual premium, coverage, term, and risk multiplier, with a "Get another quote" link back to `/`.
- **Styling** ([`styles.css`](../webapp/static/styles.css)) — CSS custom properties for theming, two-column responsive grid (`.grid-2`), no JS, no external CSS frameworks.

### 5.6 Test-hook contract

The following `data-testid` values are part of the contract with `simplelife-tests`:

| Element | testid |
|---|---|
| Quote form | `quote-form` |
| Form fields | `full_name`, `age`, `gender`, `smoker`, `health`, `coverage_amount`, `term_years` |
| Submit button | `submit-quote` |
| Form-error banner | `form-error` |
| Result section | `quote-result` |
| Applicant name on result | `applicant-name` |
| Result fields | `monthly-premium`, `annual-premium`, `coverage-display`, `term-display`, `risk-score` |
| Result CTA | `new-quote` |
| About page wrapper | `about-page` |

Renaming or removing any of these is a **breaking change** to the test suite and must be coordinated.

### 5.7 Configuration

`python-dotenv` is loaded at import time of [`main.py`](../webapp/main.py#L23). Runtime knobs:

| Env var | Default | Purpose |
|---|---|---|
| `WEBAPP_HOST` | `127.0.0.1` | uvicorn bind address |
| `WEBAPP_PORT` | `8000` | uvicorn bind port |

There are no secrets or external-service credentials in scope.

### 5.8 Entry points

- **Module:** `python -m webapp.main` → calls `run()` → `uvicorn.run(...)` with reload disabled.
- **Console script:** `simplelife-app` (declared in [`pyproject.toml`](../pyproject.toml#L20)) → same `run()`.
- **ASGI:** `webapp.main:app` for direct uvicorn/gunicorn invocation.

---

## 6. Build, Packaging & Deployment

### 6.1 Packaging

- Build backend: `setuptools >= 68` ([`pyproject.toml`](../pyproject.toml)).
- Discovery: `tool.setuptools.packages.find` with `include = ["webapp*"]`.
- Package data: `templates/*.html` and `static/*` are shipped with the wheel.
- Distribution name: `simplelife-app`, version `0.1.0`.

### 6.2 Runtime dependencies

Pinned floor versions in both [`pyproject.toml`](../pyproject.toml) and [`requirements.txt`](../requirements.txt):

- `fastapi >= 0.115.0`
- `uvicorn[standard] >= 0.32.0`
- `jinja2 >= 3.1.4`
- `python-multipart >= 0.0.12` (required for `Form(...)` parsing)
- `pydantic >= 2.9.0`
- `python-dotenv >= 1.0.1`

No upper bounds — Phase-1 demo, accepts the trade-off.

### 6.3 Local run

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .
python -m webapp.main
```

### 6.4 CI

[`/.github/workflows/ci.yml`](../.github/workflows/ci.yml) — single job `lint-and-smoke` on Ubuntu / Python 3.12:

1. Install the package editable.
2. Run `ruff check webapp/` (advisory — failures do not block).
3. Run a TestClient smoke that:
   - Asserts `/health`, `/`, `/about` all return 200.
   - Asserts `/api/quote` returns 200 for a representative request and prints the JSON.

Triggers: PRs to `main`, pushes to `main`, manual `workflow_dispatch`.

---

## 7. Error Handling

| Error class | Source | Response |
|---|---|---|
| `pydantic.ValidationError` | DTO instantiation in either route | Form: re-render `index.html` with `error` text and HTTP 400. API: HTTP 400 with `{"detail": "..."}`. |
| `ValueError` from engine `_validate` | Domain-rule violation that Pydantic didn't catch (e.g., `term_years` not in the allowed set) | Same as above. |
| Anything else | Unhandled framework path | Default FastAPI 500. No custom 500 handler in Phase 1. |

Validation messages are passed through verbatim — they are intended for the demo audience, not end users, and are acceptable to surface as-is.

---

## 8. Security & Privacy Considerations

- **No PII persisted** — quote inputs are processed in-request and discarded. There is no database, no logging of inputs, and no telemetry.
- **No authentication or authorization** — every endpoint is public. Acceptable for a demo; would be required before any real-world deployment.
- **No rate limiting / abuse controls** — out of scope for Phase 1.
- **Form CSRF** — not implemented. The form is unauthenticated and idempotent (no state change), so the practical risk is low for the demo, but this would be a gap for production.
- **Secret hygiene** — `.env`, `.env.local`, and `*.key` are gitignored ([`.gitignore`](../.gitignore)).

---

## 9. Assumptions & Constraints

1. **The premium formula is illustrative.** It is documented as not actuarially sound in both the README and the `/about` page. Anyone changing the formula must update tests in `simplelife-tests` that pin specific numeric outputs.
2. **English-only UI.** No i18n scaffolding present.
3. **Single-tenant, single-process.** No assumption of concurrency beyond what a single uvicorn worker provides.
4. **No persistence layer.** Adding one is out of scope for Phase 1.
5. **Browser support follows native HTML5.** Templates use standard form controls only.

---

## 10. Open Items / Future Phases

These are gaps observed in the current code, **not** commitments:

- [`designs/`](../designs/) is a deliberate placeholder for Phase-2 wireframes.
- No in-repo unit tests for `quote_engine.py` — currently covered transitively by the sibling test repo and the CI smoke. A small `tests/test_quote_engine.py` would close that gap without touching the test repo.
- `ruff` runs advisory. Promoting it to a merge gate would harden quality but is intentionally deferred.
- Python 3.12 in CI vs `>=3.10` declared support vs 3.14 locally on at least one dev machine — a matrix build would surface compatibility regressions earlier.
- No structured logging or request-id propagation — acceptable for a demo, would be table stakes for production.
- No Dockerfile / deployment manifest — the app is run-locally-only today.

---

## 11. Traceability

| Requirement | Realized in |
|---|---|
| FR-1 | [`main.py:53`](../webapp/main.py#L53), [`index.html`](../webapp/templates/index.html) |
| FR-2 | [`main.py:63`](../webapp/main.py#L63), [`quote.html`](../webapp/templates/quote.html) |
| FR-3 | [`main.py:58`](../webapp/main.py#L58), [`about.html`](../webapp/templates/about.html) |
| FR-4 | [`main.py:85`](../webapp/main.py#L85) (error branch) |
| FR-5 | [`quote.html:31`](../webapp/templates/quote.html#L31) ("Get another quote") |
| FR-6 | [`main.py:100`](../webapp/main.py#L100) |
| FR-7 | [`main.py:136`](../webapp/main.py#L136) |
| FR-8 | All `data-testid` occurrences across [`templates/`](../webapp/templates/) |
| DR-1…DR-7 | [`quote_engine.py:55`](../webapp/quote_engine.py#L55) (`calculate_quote`) |
| Validation rules | [`main.py:32`](../webapp/main.py#L32) (`QuoteRequest`) and [`quote_engine.py:44`](../webapp/quote_engine.py#L44) (`_validate`) |
| NFR-7 | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) |
