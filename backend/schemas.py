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
    dropoff_location: Optional[str] = Field(
        None, max_length=255, description="Free-text dropoff address/landmark (MVP)"
    )
    # Mandi coordinates from the district/mandi picker. Optional — a farmer
    # can still submit with only a text dropoff_location.
    dropoff_lat: Optional[float] = Field(None, ge=-90, le=90)
    dropoff_lng: Optional[float] = Field(None, ge=-180, le=180)


class ProduceRequestResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    farmer_id: UUID
    crop_type: str
    crate_count: int
    weight_kg: float
    latitude: float
    longitude: float
    dropoff_location: Optional[str] = None
    dropoff_lat: Optional[float] = None
    dropoff_lng: Optional[float] = None
    status: str
    created_at: datetime


class NearbyProduceRequestResponse(ProduceRequestResponse):
    """Adds computed distance for the /produce-requests/nearby endpoint."""
    distance_km: float = Field(..., description="Great-circle distance from the query point")


class OtpVerifyRequest(BaseModel):
    """Body for POST /produce-requests/{request_id}/verify-otp."""
    otp: str = Field(..., min_length=4, max_length=8)


class OtpVerifyResponse(BaseModel):
    success: bool
    message: str


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
    Response for GET /produce-requests/farmer/me.

    `trip` is None while the request is still PENDING (no rider has
    accepted it yet); once a rider accepts, it carries that rider's
    identity plus the trip's own status/timestamps.

    `pickup_otp` is only exposed to the farmer who owns the request — never
    on the rider-facing /produce-requests/nearby or the unauthenticated
    /produce-requests/{id} endpoints, since a leaked OTP defeats its
    purpose as a handoff check.
    """

    trip: Optional[TripSummary] = None
    pickup_otp: Optional[str] = None


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


# ---------------------------------------------------------------------------
# Settlement schemas
# ---------------------------------------------------------------------------

class SettlementCreate(BaseModel):
    """
    Body for POST /settlements/. The caller (usually the rider completing a
    delivery) supplies the distance covered; `rate_per_kg` is the mandi price
    per kg for the crop, used to compute the farmer's gross sale proceeds.

    `rate_per_kg` defaults to 20.0 as an MVP placeholder. When the app starts
    wiring real mandi rates in (e.g. from the /mandi-rates/ endpoint), pass
    the caller-supplied rate here instead of relying on the default.
    """
    trip_id: UUID
    distance_km: float = Field(..., gt=0, description="Distance covered for this trip, in kilometers")
    rate_per_kg: float = Field(
        20.0, gt=0,
        description="Mandi rate per kg for the crop, in ₹. Defaults to a placeholder.",
    )


class SettlementResponse(BaseModel):
    """
    Unified settlement row — carries both the rider's fare breakdown and the
    farmer's payout breakdown, so one endpoint (GET /settlements/me) serves
    both roles. Fields not relevant to the caller's role are still present
    but represent the other party's figures.

    RIDER view (populated on every row):
        base_fare, distance_fare, weight_surcharge, total_payout

    FARMER view (populated on rows created after the farmer columns were
    added — older rows have None here):
        crop_name, quantity_kg, gross_amount, rider_fare, platform_fee,
        net_payout
    """

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    trip_id: UUID
    rider_id: Optional[UUID] = None
    farmer_id: Optional[UUID] = None

    # Rider fare breakdown
    base_fare: float
    distance_fare: float
    weight_surcharge: float
    total_payout: float

    # Farmer payout breakdown — None on rows created before the farmer
    # columns existed.
    crop_name: Optional[str] = None
    quantity_kg: Optional[float] = None
    gross_amount: Optional[float] = None
    rider_fare: Optional[float] = None
    platform_fee: Optional[float] = None
    net_payout: Optional[float] = None

    # Metadata
    status: Literal["PENDING", "PAID"]
    created_at: datetime


# ---------------------------------------------------------------------------
# Admin analytics + photo upload schemas
# ---------------------------------------------------------------------------

class AdminStatsResponse(BaseModel):
    total_users: int
    total_farmers: int
    total_riders: int
    total_trips: int
    completed_trips: int
    total_payout_volume: float


class PhotoUploadResponse(BaseModel):
    image_url: str