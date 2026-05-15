<#
.SYNOPSIS
  Seeds the SimpleLife GitHub Project with backlog items derived from docs/design.md.

.DESCRIPTION
  Creates 5 requirement-related labels (if missing), 17 issues (FR-1..8 and NFR-1..9),
  and adds each issue to the specified GitHub Project.

  Source of truth for issue bodies: docs/design.md

.PARAMETER Owner
  GitHub user/org that owns both the repo and the project. Default: diro3307

.PARAMETER Repo
  Repo name (without owner). Default: simplelife-app

.PARAMETER ProjectNumber
  GitHub Project (v2) number. Default: 7 (the "SimpleLife" project)

.PARAMETER DryRun
  Print every action that would be taken without calling the GitHub API.

.EXAMPLE
  .\scripts\seed-backlog.ps1 -DryRun
  .\scripts\seed-backlog.ps1
#>
param(
    [string]$Owner = "diro3307",
    [string]$Repo = "simplelife-app",
    [int]$ProjectNumber = 7,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
Write-Step "Pre-flight: gh CLI authentication"
$authOut = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "gh is not authenticated. Run 'gh auth login' first."
}
Write-Ok "gh authenticated."

$repoSlug = "$Owner/$Repo"
Write-Host "    Repo:    $repoSlug"
Write-Host "    Project: #$ProjectNumber (owner: $Owner)"
if ($DryRun) { Write-Warn2 "DRY RUN mode - no GitHub mutations will occur." }

# ---------------------------------------------------------------------------
# 1. Labels
# ---------------------------------------------------------------------------
$labels = @(
    @{ Name = "requirement";            Color = "0E8A16"; Desc = "Tracked requirement from docs/design.md" },
    @{ Name = "phase-1";                Color = "FBCA04"; Desc = "Phase-1 demo scope" },
    @{ Name = "functional-requirement"; Color = "1D76DB"; Desc = "Functional requirement (FR-*)" },
    @{ Name = "non-functional";         Color = "5319E7"; Desc = "Non-functional requirement (NFR-*)" },
    @{ Name = "domain-rule";            Color = "B60205"; Desc = "Touches the deterministic quote formula (DR-*)" }
)

Write-Step "Ensuring labels exist on $repoSlug"
foreach ($lbl in $labels) {
    if ($DryRun) {
        Write-Skip "[dry-run] would ensure label '$($lbl.Name)' (#$($lbl.Color))"
        continue
    }
    # Try create; if it already exists, gh returns non-zero -> fall through to edit.
    $null = gh label create $lbl.Name --color $lbl.Color --description $lbl.Desc --repo $repoSlug 2>&1
    if ($LASTEXITCODE -ne 0) {
        $null = gh label edit $lbl.Name --color $lbl.Color --description $lbl.Desc --repo $repoSlug 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create or edit label '$($lbl.Name)'."
        }
        Write-Skip "label '$($lbl.Name)' already existed; updated."
    } else {
        Write-Ok "created label '$($lbl.Name)'."
    }
}

# ---------------------------------------------------------------------------
# 2. Backlog definitions (bodies sourced from docs/design.md)
# ---------------------------------------------------------------------------

# Common label set helpers
$baseFR  = @("requirement", "phase-1", "functional-requirement")
$baseNFR = @("requirement", "phase-1", "non-functional")

$backlog = @(
    # ----- Functional Requirements -----
    @{
        Id = "FR-1"
        Title = "FR-1: Home page renders the quote-request form"
        Labels = $baseFR
        Body = @'
## Requirement
A visitor can open the home page (`GET /`) and see a quote-request form with fields for full name, age, gender, smoker status, health rating, coverage amount, and term length.

## Acceptance Criteria
- [ ] `GET /` returns HTTP 200 with the rendered `index.html` template.
- [ ] The form contains all 7 input controls (`full_name`, `age`, `gender`, `smoker`, `health`, `coverage_amount`, `term_years`) and a submit button.
- [ ] Native HTML5 constraints (`min`, `max`, `required`, `maxlength`) are present on each control.
- [ ] The page extends `base.html` and renders the header (brand + nav) and footer.

## Traceability
- Code: `webapp/main.py:53` (`index` handler)
- Template: `webapp/templates/index.html`
- Design doc: docs/design.md sections 2.1, 5.1, 5.5

## Out of scope
- Server-side validation (covered by FR-4)
- data-testid attributes (covered by FR-8)
'@
    },
    @{
        Id = "FR-2"
        Title = "FR-2: Submit form returns calculated illustrative premium"
        Labels = $baseFR + "domain-rule"
        Body = @'
## Requirement
`POST /quote` accepts the form payload, validates it, calculates a deterministic illustrative premium using the documented formula, and renders the result page.

## Acceptance Criteria
- [ ] `POST /quote` with a valid payload returns HTTP 200 and renders `quote.html`.
- [ ] Result page displays monthly premium, annual premium, coverage, term, risk multiplier, and the applicant name.
- [ ] Premium values match the formula in DR-1..DR-7:
  - Base rate per $1,000 = `0.50 + (age - 18) * 0.04`
  - Smoker multiplier = `1.75` if smoker == "yes" else `1.00`
  - Health multiplier ∈ `{excellent: 0.85, good: 1.00, average: 1.25, poor: 1.75}`
  - Term multiplier = `1.00 + (term_years - 10) * 0.03`
  - `risk_score = round(smoker_mult * health_mult * term_mult, 3)`
  - `annual_premium = (coverage_amount / 1000) * base_rate * risk_score`, rounded to 2 dp
  - `monthly_premium = annual_premium / 12`, rounded to 2 dp
- [ ] Worked example holds: age 30, non-smoker, good health, $100k coverage, 20 yrs → monthly $10.62, annual $127.40, risk 1.30.
- [ ] All field validation rules (full_name 1-120; age 18-75; gender enum; smoker enum; health enum; coverage 10k-5M; term_years in {10,15,20,25,30}) are enforced.

## Traceability
- Code: `webapp/main.py:63` (`quote_form`), `webapp/quote_engine.py:55` (`calculate_quote`)
- Template: `webapp/templates/quote.html`
- Design doc: docs/design.md sections 2.1, 2.3 (DR-1..7), 2.4, 5.4

## Out of scope
- JSON endpoint (covered by FR-6)
- Error rendering (covered by FR-4)
'@
    },
    @{
        Id = "FR-3"
        Title = "FR-3: About page explains the quote calculation"
        Labels = $baseFR + "documentation"
        Body = @'
## Requirement
`GET /about` renders an informational page explaining what SimpleLife is and how the quote is calculated.

## Acceptance Criteria
- [ ] `GET /about` returns HTTP 200 with the rendered `about.html` template.
- [ ] Page explains the base rate, smoker multiplier, health rating effect, and term increment in plain language.
- [ ] Page explicitly notes that the formula is illustrative and not actuarially sound.
- [ ] The about-page wrapper carries the `data-testid="about-page"` attribute.

## Traceability
- Code: `webapp/main.py:58` (`about` handler)
- Template: `webapp/templates/about.html`
- Design doc: docs/design.md sections 2.1, 5.1

## Out of scope
- Internationalization
'@
    },
    @{
        Id = "FR-4"
        Title = "FR-4: Invalid form submissions re-render with an error (no 5xx)"
        Labels = $baseFR
        Body = @'
## Requirement
When the form payload fails validation (Pydantic) or domain checks (engine `_validate`), the response re-renders `index.html` with the error message and an HTTP 400 status. No unhandled exception, no 5xx.

## Acceptance Criteria
- [ ] Submitting `POST /quote` with `age=10` returns HTTP 400 and renders `index.html` with an `error` template variable populated.
- [ ] The `form-error` testid element is present on the re-rendered page.
- [ ] Pydantic `ValidationError` and engine `ValueError` are both caught and produce the same shape of response.
- [ ] The thrown error message text is passed through verbatim (acceptable for the demo audience).

## Traceability
- Code: `webapp/main.py:85` (error branch in `quote_form`)
- Code: `webapp/quote_engine.py:44` (`_validate`)
- Design doc: docs/design.md sections 2.1, 5.4, 7

## Out of scope
- API error format (covered by FR-6)
'@
    },
    @{
        Id = "FR-5"
        Title = "FR-5: Result page offers a 'Get another quote' path back to the form"
        Labels = $baseFR
        Body = @'
## Requirement
After receiving a quote, the visitor must have a clear way to return to the form and request a new quote without manually navigating.

## Acceptance Criteria
- [ ] `quote.html` contains an anchor/link pointing to `/`.
- [ ] The link carries `data-testid="new-quote"`.
- [ ] Clicking the link returns the user to `GET /` with HTTP 200 and an empty form.

## Traceability
- Template: `webapp/templates/quote.html:31`
- Design doc: docs/design.md sections 2.1, 5.5

## Out of scope
- Preserving prior form values across navigation
'@
    },
    @{
        Id = "FR-6"
        Title = "FR-6: GET /api/quote returns the same computed quote as JSON"
        Labels = $baseFR + "domain-rule"
        Body = @'
## Requirement
`GET /api/quote` exposes the same quote calculation as the form path, returning JSON, for use by the sibling test/agent repos.

## Acceptance Criteria
- [ ] `GET /api/quote` with all 7 query parameters returns HTTP 200 and a JSON body matching the documented contract:
  - `applicant` (full echo of the validated input)
  - `monthly_premium`, `annual_premium`, `coverage_amount`, `term_years`, `risk_score`
- [ ] Validation failures return HTTP 400 with `{"detail": "<message>"}`.
- [ ] Computed numbers match the form path bit-for-bit for the same inputs.
- [ ] All validation rules from FR-2 apply identically.

## Traceability
- Code: `webapp/main.py:100` (`api_quote`)
- Design doc: docs/design.md sections 2.2 (FR-6), 5.3, 5.1

## Out of scope
- Pagination, rate limits, auth (none in Phase 1)
'@
    },
    @{
        Id = "FR-7"
        Title = "FR-7: GET /health returns 200 OK for liveness/CI checks"
        Labels = $baseFR
        Body = @'
## Requirement
A lightweight health endpoint returns a static OK payload so liveness probes and CI smoke checks can confirm the app is up.

## Acceptance Criteria
- [ ] `GET /health` returns HTTP 200.
- [ ] Response body is exactly `{"status": "ok"}`.
- [ ] Endpoint never reads request body, query params, or any I/O.

## Traceability
- Code: `webapp/main.py:136` (`health_check`)
- CI: `.github/workflows/ci.yml` (smoke step asserts this)
- Design doc: docs/design.md section 2.2

## Out of scope
- Deep-health / dependency checks (no external deps to check)
'@
    },
    @{
        Id = "FR-8"
        Title = "FR-8: All interactive elements expose data-testid attributes"
        Labels = $baseFR
        Body = @'
## Requirement
Every interactive form control and every result-page value carries a stable `data-testid` attribute so the sibling `simplelife-tests` Playwright suite can target it without relying on visual layout.

## Acceptance Criteria
- [ ] Form testids present: `quote-form`, `full_name`, `age`, `gender`, `smoker`, `health`, `coverage_amount`, `term_years`, `submit-quote`.
- [ ] Result testids present: `quote-result`, `applicant-name`, `monthly-premium`, `annual-premium`, `coverage-display`, `term-display`, `risk-score`, `new-quote`.
- [ ] Error testid present: `form-error`.
- [ ] About page testid present: `about-page`.
- [ ] Removing or renaming any testid is treated as a breaking change.

## Traceability
- Templates: `webapp/templates/index.html`, `quote.html`, `about.html`
- Design doc: docs/design.md sections 2.2, 5.6

## Out of scope
- Adding ARIA labels (separate accessibility concern)
'@
    },

    # ----- Non-Functional Requirements -----
    @{
        Id = "NFR-1"
        Title = "NFR-1: Python >=3.10 supported; CI targets 3.12"
        Labels = $baseNFR
        Body = @'
## Statement
The app must run on Python 3.10 or newer. CI runs against Python 3.12.

## Rationale
Declared `requires-python = ">=3.10"` in `pyproject.toml`. CI pin chosen for reproducibility.

## Verification
- [ ] `pyproject.toml` declares `requires-python = ">=3.10"`.
- [ ] `.github/workflows/ci.yml` uses `python-version: "3.12"`.
- [ ] CI smoke step succeeds on 3.12.

## Traceability
- `pyproject.toml`
- `.github/workflows/ci.yml`
- Design doc: docs/design.md section 3 (NFR-1)

## Notes
A matrix build covering 3.10, 3.11, 3.12, 3.13 is a Phase-2 enhancement.
'@
    },
    @{
        Id = "NFR-2"
        Title = "NFR-2: Single-process ASGI service with no external dependencies"
        Labels = $baseNFR
        Body = @'
## Statement
The app must remain a single-process ASGI service with no database, cache, message bus, or outbound API call.

## Rationale
Demo simplicity, deterministic test runs, and the ability for agents to spin the app up locally without provisioning infrastructure.

## Verification
- [ ] `webapp/` source contains no DB/cache/HTTP-client imports.
- [ ] `requirements.txt` lists only runtime-web dependencies.
- [ ] App boots and serves requests with `python -m webapp.main`, no other services running.

## Traceability
- `webapp/main.py`, `webapp/quote_engine.py`
- Design doc: docs/design.md sections 3 (NFR-2), 4.1
'@
    },
    @{
        Id = "NFR-3"
        Title = "NFR-3: Quote calculation is pure and deterministic"
        Labels = $baseNFR + "domain-rule"
        Body = @'
## Statement
`calculate_quote(...)` must be a pure function: same input → same output, no I/O, no global state, no randomness, no time-of-day dependencies.

## Rationale
Test suites in `simplelife-tests` pin exact numeric outputs. Any non-determinism breaks the contract.

## Verification
- [ ] `webapp/quote_engine.py` imports only the standard library.
- [ ] No use of `random`, `datetime.now()`, `time`, or environment reads inside `calculate_quote`.
- [ ] Calling `calculate_quote` twice with identical input returns identical `QuoteResult` values.

## Traceability
- Code: `webapp/quote_engine.py:55`
- Design doc: docs/design.md sections 3 (NFR-3), 2.3, 4.3
'@
    },
    @{
        Id = "NFR-4"
        Title = "NFR-4: All HTML rendered server-side via Jinja2 (no JS framework)"
        Labels = $baseNFR
        Body = @'
## Statement
All pages must be rendered server-side via Jinja2. No client-side JavaScript framework, no SPA, no bundler.

## Rationale
Demo simplicity; keeps Playwright tests targeting plain HTML; avoids build-tool complexity.

## Verification
- [ ] No `<script src="...">` tags pointing at app-owned bundles in any template.
- [ ] No `package.json` / `node_modules` / bundler config in the repo.
- [ ] All routes return HTML rendered by `TemplateResponse(...)`.

## Traceability
- `webapp/templates/`, `webapp/static/styles.css`
- Design doc: docs/design.md sections 3 (NFR-4), 5.5
'@
    },
    @{
        Id = "NFR-5"
        Title = "NFR-5: Configuration via environment variables only"
        Labels = $baseNFR
        Body = @'
## Statement
Runtime configuration must be supplied via environment variables only. No config files baked into the repo. `python-dotenv` is loaded for local dev convenience.

## Rationale
Twelve-factor style; keeps the same image/wheel deployable across environments; avoids leaking environment-specific values into commits.

## Verification
- [ ] Only `WEBAPP_HOST` and `WEBAPP_PORT` are read by `run()` in `webapp/main.py`.
- [ ] Defaults `127.0.0.1` and `8000` are applied when env vars are absent.
- [ ] No hard-coded config values elsewhere in `webapp/`.

## Traceability
- Code: `webapp/main.py:141` (`run`)
- Design doc: docs/design.md sections 3 (NFR-5), 5.7
'@
    },
    @{
        Id = "NFR-6"
        Title = "NFR-6: Secrets (.env, .env.local, *.key) must never be committed"
        Labels = $baseNFR
        Body = @'
## Statement
Secret-bearing files must remain gitignored. The repo must never contain real credentials, tokens, or private keys.

## Rationale
Operational hygiene. Even in a demo repo, leaked secrets become public training data.

## Verification
- [ ] `.gitignore` lists `.env`, `.env.local`, `*.key`.
- [ ] `git ls-files` shows no `.env*` or `*.key` files committed.
- [ ] No secrets in `pyproject.toml`, `requirements.txt`, templates, or CI workflow.

## Traceability
- `.gitignore`
- Design doc: docs/design.md sections 3 (NFR-6), 8
'@
    },
    @{
        Id = "NFR-7"
        Title = "NFR-7: CI exercises /health, /, /about, and /api/quote on every PR + push"
        Labels = $baseNFR
        Body = @'
## Statement
CI must run on every PR and push to `main`, exercising at minimum the four representative routes: `/health`, `/`, `/about`, and `/api/quote`.

## Rationale
Catches import errors, template breakage, and route regressions before merge. Cheap to maintain (TestClient, no browser).

## Verification
- [ ] `.github/workflows/ci.yml` triggers on `pull_request` and `push` to `main`.
- [ ] The smoke step asserts 200 from `/health`, `/`, `/about`.
- [ ] The smoke step asserts 200 from a sample `/api/quote` call and prints the JSON.

## Traceability
- `.github/workflows/ci.yml`
- Design doc: docs/design.md sections 3 (NFR-7), 6.4
'@
    },
    @{
        Id = "NFR-8"
        Title = "NFR-8: Ruff lint is advisory in Phase 1 (not a merge gate)"
        Labels = $baseNFR
        Body = @'
## Statement
`ruff check webapp/` runs in CI but failures do not block PR merge during Phase 1.

## Rationale
Phase-1 priority is shipping the demo and demonstrating the agent loop. Lint hardening is deliberately deferred.

## Verification
- [ ] CI invokes `ruff check webapp/` with `|| true`.
- [ ] No branch protection rule requires the lint step to pass.

## Traceability
- `.github/workflows/ci.yml`
- Design doc: docs/design.md sections 3 (NFR-8), 10

## Notes
Promoting lint to a merge gate is tracked as a Phase-2 follow-up.
'@
    },
    @{
        Id = "NFR-9"
        Title = "NFR-9: data-testid hooks are a stable contract with simplelife-tests"
        Labels = $baseNFR
        Body = @'
## Statement
The `data-testid` attributes listed in the design doc are a public contract with the sibling `simplelife-tests` Playwright suite. They must not be renamed or removed without coordinated updates to the test repo.

## Rationale
Test resilience. CSS classes and visual layout will evolve; testids must remain stable so tests don't flake on cosmetic changes.

## Verification
- [ ] Full set of testids from design doc section 5.6 is present in templates (overlaps with FR-8).
- [ ] PR description for any change that touches a testid must mention `simplelife-tests` impact.

## Traceability
- `webapp/templates/*.html`
- Design doc: docs/design.md sections 3 (NFR-9), 5.6
'@
    }
)

# ---------------------------------------------------------------------------
# 3. Create issues
# ---------------------------------------------------------------------------
Write-Step "Creating $($backlog.Count) issues on $repoSlug"
$results = New-Object System.Collections.Generic.List[object]

foreach ($item in $backlog) {
    $labelArgs = @()
    foreach ($l in $item.Labels) { $labelArgs += @("--label", $l) }

    if ($DryRun) {
        Write-Skip "[dry-run] would create issue '$($item.Title)' with labels: $($item.Labels -join ', ')"
        $results.Add([pscustomobject]@{
            Id     = $item.Id
            Number = "(dry-run)"
            Url    = "(dry-run)"
            Status = "skipped"
        }) | Out-Null
        continue
    }

    # Write body to a temp file so multi-line markdown survives intact.
    $bodyFile = Join-Path $env:TEMP ("sl-backlog-{0}.md" -f $item.Id)
    Set-Content -Path $bodyFile -Value $item.Body -Encoding utf8

    $url = & gh issue create --repo $repoSlug --title $item.Title --body-file $bodyFile @labelArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    FAILED to create '$($item.Title)':" -ForegroundColor Red
        Write-Host "    $url" -ForegroundColor Red
        Remove-Item $bodyFile -ErrorAction SilentlyContinue
        continue
    }
    $url = ($url | Select-Object -Last 1).ToString().Trim()
    $issueNumber = ($url -split "/")[-1]
    Write-Ok ("{0} -> issue #{1}" -f $item.Id, $issueNumber)
    $results.Add([pscustomobject]@{
        Id     = $item.Id
        Number = $issueNumber
        Url    = $url
        Status = "created"
    }) | Out-Null

    Remove-Item $bodyFile -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 4. Add to project
# ---------------------------------------------------------------------------
Write-Step "Adding issues to project #$ProjectNumber"
foreach ($r in $results) {
    if ($r.Status -ne "created") {
        Write-Skip "[skip] $($r.Id) was not created; not adding to project."
        continue
    }
    if ($DryRun) {
        Write-Skip "[dry-run] would add $($r.Url) to project #$ProjectNumber"
        continue
    }
    $addOut = & gh project item-add $ProjectNumber --owner $Owner --url $r.Url 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    FAILED to add $($r.Id) (#$($r.Number)) to project:" -ForegroundColor Red
        Write-Host "    $addOut" -ForegroundColor Red
        $r.Status = "created-but-not-added"
    } else {
        Write-Ok "$($r.Id) (#$($r.Number)) added to project."
    }
}

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
Write-Step "Summary"
$results | Format-Table -AutoSize Id, Number, Status, Url

if ($DryRun) {
    Write-Warn2 "Dry run complete. No GitHub mutations were made."
} else {
    $okCount = ($results | Where-Object { $_.Status -eq "created" }).Count
    Write-Ok "Done. $okCount issues created and added to project #$ProjectNumber."
    Write-Host "    Open: https://github.com/users/$Owner/projects/$ProjectNumber"
}
