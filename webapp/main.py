"""FastAPI life-insurance quote app.

Pages:
  GET  /          -> quote form
  POST /quote     -> renders quote result
  GET  /about     -> about page
  GET  /api/quote -> JSON endpoint used by tests and agents
"""
from __future__ import annotations

import os
import re
from datetime import date
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field, ValidationError, field_validator

from .quote_engine import QuoteInput, calculate_quote

# US ZIP code: 5 digits, optionally followed by "-" and 4 digits (ZIP+4).
_ZIP_RE = re.compile(r"^\d{5}(-\d{4})?$")

# ISO Date of Birth: YYYY-MM-DD.
_DOB_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")

# Human-readable labels used in field-level validation messages.
FIELD_LABELS: dict[str, str] = {
    "first_name": "First name",
    "last_name": "Last name",
    "zip_code": "Zip Code",
    "dob": "Date of Birth",
    "gender": "Gender",
    "smoker": "Smoker",
    "health": "Health rating",
    "coverage_amount": "Coverage amount",
    "term_years": "Term length",
}

# Fields rendered as <select>/dropdown that get a "Please select…" message
# (AC-3) instead of "<Field> is required" (AC-1).
SELECT_FIELDS: frozenset[str] = frozenset(
    {"gender", "smoker", "health", "term_years"}
)

# Allowed maximum lengths for free-text fields (AC-4).
TEXT_MAX_LENGTHS: dict[str, int] = {
    "first_name": 50,
    "last_name": 50,
    "zip_code": 10,
}


def _required_message(field: str) -> str:
    """Build the user-facing 'required' message for a given form field."""
    label = FIELD_LABELS.get(field, field)
    if field in SELECT_FIELDS:
        return f"Please select a {label}"
    return f"{label} is required"


def _parse_dob(value: str) -> date | None:
    """Parse a YYYY-MM-DD string into a date. Return None if unparseable."""
    if not value:
        return None
    m = _DOB_RE.match(value.strip())
    if not m:
        return None
    y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
    try:
        return date(y, mo, d)
    except ValueError:
        return None


def _age_from_dob(dob: date, today: date) -> int:
    """Full years between dob and today, birthday-aware."""
    years = today.year - dob.year
    if (today.month, today.day) < (dob.month, dob.day):
        years -= 1
    return years

load_dotenv()

BASE_DIR = Path(__file__).parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

app = FastAPI(title="SimpleLife Insurance", version="0.1.0")
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


class QuoteRequest(BaseModel):
    first_name: str = Field(min_length=1, max_length=50)
    last_name: str = Field(min_length=1, max_length=50)
    age: int = Field(ge=18, le=75)
    gender: str = Field(pattern="^(male|female|other)$")
    smoker: str = Field(pattern="^(yes|no)$")
    health: str = Field(pattern="^(excellent|good|average|poor)$")
    coverage_amount: float = Field(ge=10_000, le=5_000_000)
    term_years: int = Field()
    zip_code: str = Field()

    @field_validator("first_name", "last_name")
    @classmethod
    def _strip_and_require(cls, value: str) -> str:
        if value is None:
            raise ValueError("must not be empty")
        trimmed = value.strip()
        if not trimmed:
            raise ValueError("must not be empty or whitespace-only")
        if len(trimmed) > 50:
            raise ValueError("must be 50 characters or fewer")
        return trimmed

    @field_validator("zip_code")
    @classmethod
    def _validate_zip_code(cls, value: str) -> str:
        if value is None:
            raise ValueError("Zip Code is required")
        trimmed = value.strip()
        if not trimmed:
            raise ValueError("Zip Code is required")
        if not _ZIP_RE.match(trimmed):
            raise ValueError(
                "Zip Code must be a 5-digit US ZIP or ZIP+4 (e.g., 94110 or 94110-1234)"
            )
        return trimmed

    def to_engine_input(self) -> QuoteInput:
        return QuoteInput(
            first_name=self.first_name,
            last_name=self.last_name,
            age=self.age,
            gender=self.gender,  # type: ignore[arg-type]
            smoker=self.smoker,  # type: ignore[arg-type]
            health=self.health,  # type: ignore[arg-type]
            coverage_amount=self.coverage_amount,
            term_years=self.term_years,
        )


def _per_field_errors(exc: ValidationError) -> dict[str, str]:
    """Map Pydantic validation errors back to form field names for inline display."""
    errors: dict[str, str] = {}
    for err in exc.errors():
        loc = err.get("loc") or ()
        if not loc:
            continue
        field = str(loc[0])
        # Keep the first error per field for a clean inline message.
        errors.setdefault(field, err.get("msg", "Invalid value"))
    return errors


def _validate_form_fields(
    *,
    first_name: str,
    last_name: str,
    zip_code: str,
    dob: str,
    gender: str,
    smoker: str,
    health: str,
    coverage_amount: str,
    term_years: str,
) -> tuple[dict[str, str], dict[str, object]]:
    """Run field-level validation across every required field on the quote form.

    Implements the AC-1..AC-5 server-side checks: empty required fields,
    whitespace-only inputs, unselected dropdowns, length caps, and basic
    numeric/date parsing. Returns (field_errors, parsed_values).
    """
    field_errors: dict[str, str] = {}
    parsed: dict[str, object] = {}

    # --- Text inputs: first/last name (AC-1, AC-2, AC-4, AC-5) -----------
    for fname, raw in (("first_name", first_name), ("last_name", last_name)):
        trimmed = (raw or "").strip()
        if not trimmed:
            # AC-1 / AC-2: missing or whitespace-only.
            field_errors[fname] = _required_message(fname)
            continue
        cap = TEXT_MAX_LENGTHS[fname]
        if len(trimmed) > cap:
            # AC-4: above declared maxLength.
            field_errors[fname] = (
                f"{FIELD_LABELS[fname]} must be {cap} characters or fewer"
            )
            continue
        parsed[fname] = trimmed

    # --- Zip Code (AC-1, AC-2, AC-4) -------------------------------------
    zip_trimmed = (zip_code or "").strip()
    if not zip_trimmed:
        field_errors["zip_code"] = _required_message("zip_code")
    elif len(zip_trimmed) > TEXT_MAX_LENGTHS["zip_code"]:
        field_errors["zip_code"] = (
            "Zip Code must be 10 characters or fewer"
        )
    elif not _ZIP_RE.match(zip_trimmed):
        field_errors["zip_code"] = (
            "Zip Code must be a 5-digit US ZIP or ZIP+4 (e.g., 94110 or 94110-1234)"
        )
    else:
        parsed["zip_code"] = zip_trimmed

    # --- Date of Birth (AC-1) --------------------------------------------
    dob_trimmed = (dob or "").strip()
    if not dob_trimmed:
        field_errors["dob"] = _required_message("dob")
    else:
        parsed_dob = _parse_dob(dob_trimmed)
        if parsed_dob is None:
            field_errors["dob"] = "Please enter a valid date"
        elif parsed_dob > date.today():
            field_errors["dob"] = "Date of Birth cannot be in the future"
        else:
            parsed["dob"] = parsed_dob

    # --- Select fields (AC-3) --------------------------------------------
    gender_val = (gender or "").strip()
    if not gender_val:
        field_errors["gender"] = _required_message("gender")
    elif gender_val not in {"male", "female", "other"}:
        field_errors["gender"] = "Please select a valid Gender"
    else:
        parsed["gender"] = gender_val

    smoker_val = (smoker or "").strip()
    if not smoker_val:
        field_errors["smoker"] = _required_message("smoker")
    elif smoker_val not in {"yes", "no"}:
        field_errors["smoker"] = "Please select a valid Smoker option"
    else:
        parsed["smoker"] = smoker_val

    health_val = (health or "").strip()
    if not health_val:
        field_errors["health"] = _required_message("health")
    elif health_val not in {"excellent", "good", "average", "poor"}:
        field_errors["health"] = "Please select a valid Health rating"
    else:
        parsed["health"] = health_val

    term_val = (term_years or "").strip()
    if not term_val:
        field_errors["term_years"] = _required_message("term_years")
    else:
        try:
            term_int = int(term_val)
        except ValueError:
            field_errors["term_years"] = "Please select a valid Term length"
        else:
            if term_int not in {10, 15, 20, 25, 30}:
                field_errors["term_years"] = "Please select a valid Term length"
            else:
                parsed["term_years"] = term_int

    # --- Coverage amount (AC-1) ------------------------------------------
    cov_val = (coverage_amount or "").strip()
    if not cov_val:
        field_errors["coverage_amount"] = _required_message("coverage_amount")
    else:
        try:
            cov_float = float(cov_val)
        except ValueError:
            field_errors["coverage_amount"] = "Coverage amount must be a number"
        else:
            if cov_float < 10_000 or cov_float > 5_000_000:
                field_errors["coverage_amount"] = (
                    "Coverage amount must be between $10,000 and $5,000,000"
                )
            else:
                parsed["coverage_amount"] = cov_float

    return field_errors, parsed


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "index.html")


@app.get("/about", response_class=HTMLResponse)
async def about(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "about.html")


@app.post("/quote", response_class=HTMLResponse)
async def quote_form(
    request: Request,
    first_name: str = Form(""),
    last_name: str = Form(""),
    gender: str = Form(""),
    smoker: str = Form(""),
    health: str = Form(""),
    coverage_amount: str = Form(""),
    term_years: str = Form(""),
    zip_code: str = Form(""),
    dob: str = Form(""),
    age: str = Form(""),
    address_line1: str = Form(""),
    address_line2: str = Form(""),
    city: str = Form(""),
    state: str = Form(""),
) -> HTMLResponse:
    submitted = {
        "first_name": first_name,
        "last_name": last_name,
        "address_line1": address_line1,
        "address_line2": address_line2,
        "city": city,
        "state": state,
        "zip_code": zip_code,
        "dob": dob,
        "gender": gender,
        "smoker": smoker,
        "health": health,
        "coverage_amount": coverage_amount,
        "term_years": term_years,
    }

    # AC-1..AC-5: server-side field-level validation across every required input.
    field_errors, parsed = _validate_form_fields(
        first_name=first_name,
        last_name=last_name,
        zip_code=zip_code,
        dob=dob,
        gender=gender,
        smoker=smoker,
        health=health,
        coverage_amount=coverage_amount,
        term_years=term_years,
    )

    if field_errors:
        # AC-6: render every inline error plus an accessible summary.
        error_list = [
            {"field": fname, "message": msg}
            for fname, msg in field_errors.items()
        ]
        return templates.TemplateResponse(
            request,
            "index.html",
            {
                "error": "Please correct the highlighted fields and try again.",
                "field_errors": field_errors,
                "error_list": error_list,
                "submitted": submitted,
            },
            status_code=400,
        )

    parsed_dob: date = parsed["dob"]  # type: ignore[assignment]
    derived_age = _age_from_dob(parsed_dob, date.today())

    try:
        req = QuoteRequest(
            first_name=parsed["first_name"],  # type: ignore[arg-type]
            last_name=parsed["last_name"],  # type: ignore[arg-type]
            age=derived_age,
            gender=parsed["gender"],  # type: ignore[arg-type]
            smoker=parsed["smoker"],  # type: ignore[arg-type]
            health=parsed["health"],  # type: ignore[arg-type]
            coverage_amount=parsed["coverage_amount"],  # type: ignore[arg-type]
            term_years=parsed["term_years"],  # type: ignore[arg-type]
            zip_code=parsed["zip_code"],  # type: ignore[arg-type]
        )
        result = calculate_quote(req.to_engine_input())
    except ValidationError as exc:
        pydantic_errors = _per_field_errors(exc)
        error_list = [
            {"field": fname, "message": msg}
            for fname, msg in pydantic_errors.items()
        ]
        return templates.TemplateResponse(
            request,
            "index.html",
            {
                "error": "Please correct the highlighted fields and try again.",
                "field_errors": pydantic_errors,
                "error_list": error_list,
                "submitted": submitted,
            },
            status_code=400,
        )
    except ValueError as exc:
        return templates.TemplateResponse(
            request,
            "index.html",
            {"error": str(exc), "submitted": submitted},
            status_code=400,
        )

    return templates.TemplateResponse(
        request,
        "quote.html",
        {"applicant": req, "result": result},
    )


@app.get("/api/quote")
async def api_quote(
    first_name: str,
    last_name: str,
    age: int,
    gender: str,
    smoker: str,
    health: str,
    coverage_amount: float,
    term_years: int,
    zip_code: str = "",
) -> JSONResponse:
    try:
        req = QuoteRequest(
            first_name=first_name,
            last_name=last_name,
            age=age,
            gender=gender,
            smoker=smoker,
            health=health,
            coverage_amount=coverage_amount,
            term_years=term_years,
            zip_code=zip_code,
        )
        result = calculate_quote(req.to_engine_input())
    except (ValidationError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    return JSONResponse(
        {
            "applicant": req.model_dump(),
            "monthly_premium": result.monthly_premium,
            "annual_premium": result.annual_premium,
            "coverage_amount": result.coverage_amount,
            "term_years": result.term_years,
            "risk_score": result.risk_score,
        }
    )


@app.get("/health")
async def health_check() -> dict[str, str]:
    return {"status": "ok"}


def run() -> None:
    import uvicorn

    host = os.getenv("WEBAPP_HOST", "127.0.0.1")
    port = int(os.getenv("WEBAPP_PORT", "8000"))
    uvicorn.run("webapp.main:app", host=host, port=port, reload=False)


if __name__ == "__main__":
    run()
