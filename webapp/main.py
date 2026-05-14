"""FastAPI life-insurance quote app.

Pages:
  GET  /          -> quote form
  POST /quote     -> renders quote result
  GET  /about     -> about page
  GET  /api/quote -> JSON endpoint used by tests and agents
"""
from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field, ValidationError

from .quote_engine import QuoteInput, calculate_quote

load_dotenv()

BASE_DIR = Path(__file__).parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

app = FastAPI(title="SimpleLife Insurance", version="0.1.0")
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


class QuoteRequest(BaseModel):
    full_name: str = Field(min_length=1, max_length=120)
    age: int = Field(ge=18, le=75)
    gender: str = Field(pattern="^(male|female|other)$")
    smoker: str = Field(pattern="^(yes|no)$")
    health: str = Field(pattern="^(excellent|good|average|poor)$")
    coverage_amount: float = Field(ge=10_000, le=5_000_000)
    term_years: int = Field()

    def to_engine_input(self) -> QuoteInput:
        return QuoteInput(
            full_name=self.full_name.strip(),
            age=self.age,
            gender=self.gender,  # type: ignore[arg-type]
            smoker=self.smoker,  # type: ignore[arg-type]
            health=self.health,  # type: ignore[arg-type]
            coverage_amount=self.coverage_amount,
            term_years=self.term_years,
        )


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "index.html")


@app.get("/about", response_class=HTMLResponse)
async def about(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(request, "about.html")


@app.post("/quote", response_class=HTMLResponse)
async def quote_form(
    request: Request,
    full_name: str = Form(...),
    age: int = Form(...),
    gender: str = Form(...),
    smoker: str = Form(...),
    health: str = Form(...),
    coverage_amount: float = Form(...),
    term_years: int = Form(...),
) -> HTMLResponse:
    try:
        req = QuoteRequest(
            full_name=full_name,
            age=age,
            gender=gender,
            smoker=smoker,
            health=health,
            coverage_amount=coverage_amount,
            term_years=term_years,
        )
        result = calculate_quote(req.to_engine_input())
    except (ValidationError, ValueError) as exc:
        return templates.TemplateResponse(
            request,
            "index.html",
            {"error": str(exc)},
            status_code=400,
        )

    return templates.TemplateResponse(
        request,
        "quote.html",
        {"applicant": req, "result": result},
    )


@app.get("/api/quote")
async def api_quote(
    full_name: str,
    age: int,
    gender: str,
    smoker: str,
    health: str,
    coverage_amount: float,
    term_years: int,
) -> JSONResponse:
    try:
        req = QuoteRequest(
            full_name=full_name,
            age=age,
            gender=gender,
            smoker=smoker,
            health=health,
            coverage_amount=coverage_amount,
            term_years=term_years,
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
