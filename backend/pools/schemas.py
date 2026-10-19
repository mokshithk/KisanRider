"""
Pydantic v2 schemas for the KisanRider farmer-pooling feature.

Phases:
  * Phase 1 — initial shape.
  * Phase 2 — PoolCreate gains ``produce_request_id`` / ``weight_kg`` /
              ``auto_approve``; PoolOut gains ``auto_approve``; PoolMemberOut
              gains ``produce_request_id``. (Catch-up applied in Phase 3 to
              fix the 500 on POST /pools/.)
  * Phase 3 — adds ``PoolAcceptResult`` for the rider-accept endpoint.

These mirror the conventions established by ``backend/schemas.py``:

  * ``ConfigDict(from_attributes=True)`` on every schema that reads from
    a SQLAlchemy row.
  * ``Optional[X] = None`` for every nullable field, so the wire contract
    is explicit.
  * ``Field(...)`` bounds for length / range checks.

**Do not import from ``backend/schemas.py``.** These are self-contained.
"""

from datetime import datetime
from typing import List, Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

class PoolCreate(BaseModel):
    """
    Body for ``POST /pools/``.

    The *creator* is resolved from the JWT (``require_role("FARMER")``),
    but the creator's *contribution* is supplied explicitly:

      * ``produce_request_id`` — the creator's existing PENDING
        ProduceRequest the pool is anchored to. Validated server-side to
        belong to the creator, be PENDING, and not be linked to another
        active pool.
      * ``weight_kg`` — the portion of that harvest the creator is pooling.
        May be less than the ProduceRequest's own weight if only part of
        the harvest is pooled. Must be ≤ ``max_qty`` — a single farmer
        cannot fill the pool by themselves.

    ``auto_approve`` selects the join mode (D3 = 3B):

      * ``True``  (default) — auto-match pool: joins land as ACCEPTED.
      * ``False`` — manual pool: joins land as REQUESTED, creator approves.
    """

    # ----- Creator's contribution -----------------------------------------
    produce_request_id: UUID
    weight_kg: float = Field(
        ..., gt=0,
        description=(
            "Creator's contribution in kilograms. Must be ≤ max_qty. May "
            "differ from the ProduceRequest's own weight if only part of "
            "the harvest is pooled."
        ),
    )

    # ----- Pool metadata --------------------------------------------------
    crop_type: str = Field(..., min_length=1, max_length=80)

    pickup_window_start: datetime
    pickup_window_end: datetime

    min_qty: float = Field(
        ..., gt=0,
        description="Minimum total weight in kilograms for the pool to proceed.",
    )
    max_qty: float = Field(
        ..., gt=0,
        description="Maximum total weight in kilograms the pool will accept.",
    )

    # ----- Destination (mirrors ProduceRequest) ---------------------------
    dropoff_district: Optional[str] = Field(None, max_length=80)
    dropoff_mandi_id: Optional[str] = Field(None, max_length=160)
    dropoff_mandi_name: Optional[str] = Field(None, max_length=200)
    dropoff_stall_number: Optional[str] = Field(None, max_length=80)

    # ----- Join mode (D3 = 3B) --------------------------------------------
    auto_approve: bool = Field(
        True,
        description=(
            "True → auto-match pool: joins land as ACCEPTED immediately.\n"
            "False → manual pool: joins land as REQUESTED; creator must "
            "approve each."
        ),
    )

    notes: Optional[str] = Field(None, max_length=2000)

    @model_validator(mode="after")
    def _check_consistency(self) -> "PoolCreate":
        """Reject windows and quantity ranges that can never be satisfied."""
        if self.pickup_window_end <= self.pickup_window_start:
            raise ValueError(
                "pickup_window_end must be strictly after pickup_window_start"
            )
        if self.max_qty < self.min_qty:
            raise ValueError("max_qty must be >= min_qty")
        if self.weight_kg > self.max_qty:
            raise ValueError(
                "Creator's weight_kg must be <= max_qty; a single farmer "
                "cannot exceed the pool's total capacity."
            )
        return self


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

class PoolOut(BaseModel):
    """
    Response shape for ``GET /pools/nearby`` (and the base of
    ``PoolDetailOut``).

    ``member_count`` counts only **ACCEPTED** members — the ones committed
    to the pool. Pending (REQUESTED) members are excluded; the caller can
    inspect them via ``GET /pools/{id}``.
    """

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    creator_id: UUID
    creator_full_name: Optional[str] = None

    crop_type: str

    pickup_window_start: datetime
    pickup_window_end: datetime

    min_qty: float
    max_qty: float
    current_qty: float

    status: str
    auto_approve: bool = True

    dropoff_district: Optional[str] = None
    dropoff_mandi_id: Optional[str] = None
    dropoff_mandi_name: Optional[str] = None
    dropoff_stall_number: Optional[str] = None

    notes: Optional[str] = None

    member_count: int = 0
    created_at: datetime
    locked_at: Optional[datetime] = None


# ---------------------------------------------------------------------------
# Membership
# ---------------------------------------------------------------------------

class PoolMemberCreate(BaseModel):
    """
    Body for ``POST /pools/{id}/join``.

    The farmer is resolved from the JWT; the ProduceRequest is validated
    server-side to belong to them, be PENDING, and not already be linked
    to another active pool.
    """

    produce_request_id: UUID
    weight_kg: float = Field(..., gt=0, description="Weight in kilograms.")


class PoolMemberOut(BaseModel):
    """
    One member as exposed to a farmer viewing the pool detail.

    Includes ``produce_request_id`` so the client can cross-reference the
    underlying ProduceRequest without a second call.
    """

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    farmer_id: UUID
    produce_request_id: UUID
    weight_kg: float
    status: str
    requested_at: datetime
    decided_at: Optional[datetime] = None
    cancellation_reason: Optional[str] = None


# ---------------------------------------------------------------------------
# Stops (route order)
# ---------------------------------------------------------------------------

class PoolStopOut(BaseModel):
    """A single pickup stop in the pool's future route."""

    model_config = ConfigDict(from_attributes=True)

    sequence: int
    produce_request_id: UUID
    status: str


# ---------------------------------------------------------------------------
# Detail (PoolOut + members + stops)
# ---------------------------------------------------------------------------

class PoolDetailOut(PoolOut):
    """
    Response for ``GET /pools/{id}`` and the mutating pool endpoints.

    Both lists default to empty so a freshly-created pool (no members
    yet, no stops yet) renders cleanly without null checks on the client.
    """

    members: List[PoolMemberOut] = Field(default_factory=list)
    stops: List[PoolStopOut] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Phase 3 — rider accept result
# ---------------------------------------------------------------------------

class PoolAcceptResult(BaseModel):
    """
    Response for ``POST /pools/{id}/accept``.

    Per D1 = Option A, accepting a pool materialises **one Trip per
    accepted member**. The new trips are listed here so the rider's
    client can immediately drill into any one of them without a second
    lookup.

    ``pool_status`` is ``"DRIVER_ASSIGNED"`` after a successful accept.
    """

    pool_id: UUID
    pool_status: str
    trip_ids: List[UUID] = Field(default_factory=list)
    trips_created: int = 0