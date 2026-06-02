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


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "index.html")


@app.get("/about", response_class=HTMLResponse)
async def about(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "about.html")


@app.post("/quote", response_class=HTMLResponse)
async def quote_form(
    request: Request,
    first_name: str = Form(...),
    last_name: str = Form(...),
    gender: str = Form(...),
    smoker: str = Form(...),
    health: str = Form(...),
    coverage_amount: float = Form(...),
    term_years: int = Form(...),
    zip_code: str = Form(""),
    dob: str = Form(""),
    age: int | None = Form(None),
) -> HTMLResponse:
    submitted = {
        "first_name": first_name,
        "last_name": last_name,
        "zip_code": zip_code,
        "dob": dob,
    }

    # AC-4/AC-5: validate DOB before falling through to business validation.
    # DOB is the source of truth on the UI form; derive age from it.
    field_errors: dict[str, str] = {}
    parsed_dob = _parse_dob(dob)
    if dob == "" and age is None:
        field_errors["dob"] = "Please enter a valid date"
    elif dob != "" and parsed_dob is None:
        field_errors["dob"] = "Please enter a valid date"
    elif parsed_dob is not None and parsed_dob > date.today():
        field_errors["dob"] = "Date of Birth cannot be in the future"

    if field_errors:
        return templates.TemplateResponse(
            request,
            "index.html",
            {
                "error": next(iter(field_errors.values())),
                "field_errors": field_errors,
                "submitted": submitted,
            },
            status_code=400,
        )

    derived_age = (
        _age_from_dob(parsed_dob, date.today()) if parsed_dob is not None else age
    )

    try:
        req = QuoteRequest(
            first_name=first_name,
            last_name=last_name,
            age=derived_age,
            gender=gender,
            smoker=smoker,
            health=health,
            coverage_amount=coverage_amount,
            term_years=term_years,
            zip_code=zip_code,
        )
        result = calculate_quote(req.to_engine_input())
    except ValidationError as exc:
        return templates.TemplateResponse(
            request,
            "index.html",
            {
                "error": str(exc),
                "field_errors": _per_field_errors(exc),
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
