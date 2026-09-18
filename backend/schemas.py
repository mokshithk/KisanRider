"""
Pydantic validation schemas for KisanRider.

Design note: PostGIS geometry columns (GeoAlchemy2 WKBElement) are never
exposed directly over the API. Inbound requests take plain latitude/longitude
floats; outbound responses are built explicitly in crud.py (via
`shape.to_shape(...)`) into plain floats, then validated against
ProduceRequestResponse. That's why ProduceRequestResponse has no
`pickup_location` field at all — only `latitude` / `longitude`.
"""

from datetime import datetime
from typing import Literal, Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator


# ---------------------------------------------------------------------------
# User schemas
# ---------------------------------------------------------------------------

class UserCreate(BaseModel):
    phone: str = Field(..., min_length=10, max_length=15, description="E.164 or local phone number")
    role: Literal["FARMER", "RIDER"]
    full_name: str = Field(..., min_length=1, max_length=120)

    @field_validator("phone")
    @classmethod
    def phone_digits_only(cls, v: str) -> str:
        cleaned = v.strip()
        digits = cleaned.lstrip("+")
        if not digits.isdigit():
            raise ValueError("phone must contain only digits and an optional leading '+'")
        return cleaned


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    phone: str
    role: Literal["FARMER", "RIDER"]
    full_name: str
    created_at: datetime


# ---------------------------------------------------------------------------
# ProduceRequest schemas
# ---------------------------------------------------------------------------

class ProduceRequestCreate(BaseModel):
    crop_type: str = Field(..., min_length=1, max_length=80)
    crate_count: int = Field(..., gt=0, description="Number of crates, must be positive")
    weight_kg: float = Field(..., gt=0, description="Total weight in kilograms")
    latitude: float = Field(..., ge=-90, le=90)
    longitude: float = Field(..., ge=-180, le=180)


class ProduceRequestResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    farmer_id: UUID
    crop_type: str
    crate_count: int
    weight_kg: float
    latitude: float
    longitude: float
    status: str
    created_at: datetime


class NearbyProduceRequestResponse(ProduceRequestResponse):
    """Adds computed distance for the /produce-requests/nearby endpoint."""
    distance_km: float = Field(..., description="Great-circle distance from the query point")


# ---------------------------------------------------------------------------
# Trip schemas
# ---------------------------------------------------------------------------

TripStatus = Literal["ACCEPTED", "PICKED_UP", "DELIVERED", "CANCELLED"]


class TripCreate(BaseModel):
    produce_request_id: UUID
    rider_id: UUID


class TripResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    produce_request_id: UUID
    rider_id: UUID
    status: TripStatus
    created_at: datetime
    completed_at: Optional[datetime] = None


class TripStatusUpdate(BaseModel):
    """
    Body for PATCH /trips/{trip_id}/status.

    'ACCEPTED' is deliberately excluded here — a trip starts in that state
    via POST /trips/accept and is never transitioned back into it, so this
    is a Literal of only the three valid forward targets. FastAPI/Pydantic
    reject anything else with a 422 before it ever reaches crud.py.
    """

    status: Literal["PICKED_UP", "DELIVERED", "CANCELLED"]


class ActiveTripResponse(TripResponse):
    """
    Response for GET /trips/active. Adds the associated produce request
    (crop details + pickup coordinates) so a rider's app doesn't need a
    second round-trip to /produce-requests/{id} just to know where to go
    and what to pick up.
    """

    produce_request: ProduceRequestResponse


# ---------------------------------------------------------------------------
# Farmer produce-request tracking feed
# ---------------------------------------------------------------------------

class RiderSummary(BaseModel):
    """Minimal rider identity shown to a farmer once their request is picked up."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    full_name: str
    phone: str


class TripSummary(BaseModel):
    """Trip status/timing, nested under a farmer's produce request view."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    status: TripStatus
    created_at: datetime
    completed_at: Optional[datetime] = None
    rider: Optional[RiderSummary] = None


class FarmerProduceRequestResponse(ProduceRequestResponse):
    """
    Response for GET /produce-requests/farmer/{farmer_id}.

    `trip` is None while the request is still PENDING (no rider has
    accepted it yet); once a rider accepts, it carries that rider's
    identity plus the trip's own status/timestamps.
    """

    trip: Optional[TripSummary] = None


# ---------------------------------------------------------------------------
# CrateScan schemas
# ---------------------------------------------------------------------------

class CrateScanCreate(BaseModel):
    trip_id: UUID
    scan_type: Literal["PICKUP", "DELIVERY"]
    qr_code: str = Field(..., min_length=1, max_length=255)


class CrateScanResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    trip_id: UUID
    scanned_by_id: UUID
    scan_type: Literal["PICKUP", "DELIVERY"]
    qr_code: str
    scanned_at: datetime