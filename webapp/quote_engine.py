"""Life-insurance premium calculation.

Illustrative only — not actuarially sound. Designed to be easy for tests
to pin down with deterministic numbers.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Literal


Smoker = Literal["yes", "no"]
HealthRating = Literal["excellent", "good", "average", "poor"]


@dataclass(frozen=True)
class QuoteInput:
    first_name: str
    last_name: str
    age: int
    gender: Literal["male", "female", "other"]
    smoker: Smoker
    health: HealthRating
    coverage_amount: float
    term_years: int
    title: str = ""

    @property
    def full_name(self) -> str:
        """Convenience: combined display name (kept for templates / logs)."""
        parts = [self.title, self.first_name, self.last_name]
        return " ".join(p for p in (p.strip() for p in parts) if p)


@dataclass(frozen=True)
class QuoteResult:
    monthly_premium: float
    annual_premium: float
    coverage_amount: float
    term_years: int
    risk_score: float


HEALTH_MULTIPLIER: dict[HealthRating, float] = {
    "excellent": 0.85,
    "good": 1.00,
    "average": 1.25,
    "poor": 1.75,
}


def _validate(q: QuoteInput) -> None:
    if not q.first_name or not q.first_name.strip():
        raise ValueError("first_name is required")
    if not q.last_name or not q.last_name.strip():
        raise ValueError("last_name is required")
    if not 18 <= q.age <= 75:
        raise ValueError("age must be between 18 and 75")
    if q.coverage_amount < 10_000 or q.coverage_amount > 5_000_000:
        raise ValueError("coverage_amount must be between 10,000 and 5,000,000")
    if q.term_years not in (10, 15, 20, 25, 30):
        raise ValueError("term_years must be one of 10, 15, 20, 25, 30")


def calculate_quote(q: QuoteInput) -> QuoteResult:
    """Compute a deterministic illustrative life-insurance premium.

    Formula intentionally simple and stable so tests can pin exact values.
    """
    _validate(q)

    # Base rate per $1,000 of coverage, scaling with age.
    base_rate_per_1000 = 0.50 + (q.age - 18) * 0.04

    # Risk multipliers.
    smoker_mult = 1.75 if q.smoker == "yes" else 1.0
    health_mult = HEALTH_MULTIPLIER[q.health]
    term_mult = 1.0 + (q.term_years - 10) * 0.03

    risk_score = round(smoker_mult * health_mult * term_mult, 3)

    annual = (q.coverage_amount / 1000.0) * base_rate_per_1000 * risk_score
    monthly = annual / 12.0

    return QuoteResult(
        monthly_premium=round(monthly, 2),
        annual_premium=round(annual, 2),
        coverage_amount=q.coverage_amount,
        term_years=q.term_years,
        risk_score=risk_score,
    )
