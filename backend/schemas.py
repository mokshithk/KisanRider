"""
Pydantic validation schemas for KisanRider.

Design note: PostGIS geometry columns (GeoAlchemy2 WKBElement) are never
exposed directly over the API. Inbound requests take plain latitude/longitude
floats; outbound responses are built explicitly in crud.py (via
`shape.to_shape(...)`) into plain floats, then validated against
ProduceRequestResponse.
"""

from datetime import datetime
from typing import Literal, Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator


# ---------------------------------------------------------------------------
# User schemas
# ---------------------------------------------------------------------------

class UserCreate(BaseModel):
    """Legacy /users/ path — no password, no OTP. Kept for backward compat."""
    phone: str = Field(..., min_length=10, max_length=15)
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
    """Legacy /users/ response shape (includes phone + created_at)."""
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    email: str
    phone: Optional[str] = None
    role: Literal["FARMER", "RIDER"]
    full_name: str
    created_at: datetime
    district: Optional[str] = None
    state: Optional[str] = None


class UserOut(BaseModel):
    """
    Public-facing user profile returned with auth tokens.

    Deliberately narrower than UserResponse — no phone, no created_at.
    Matches the shape the Flutter client expects on signup/login.
    """
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    full_name: str
    email: str
    role: Literal["FARMER", "RIDER"]
    state: Optional[str] = None
    district: Optional[str] = None
    is_verified: bool = True


# ---------------------------------------------------------------------------
# Signup / OTP schemas
# ---------------------------------------------------------------------------

class UserSignUp(BaseModel):
    """
    Body for POST /auth/signup. Validated in full before any OTP is sent,
    so a typo in the email fails fast rather than after a wasted SMTP
    round trip.
    """
    full_name: str = Field(..., min_length=1, max_length=120)
    email: EmailStr
    password: str = Field(..., min_length=6, max_length=128)
    role: Literal["FARMER", "RIDER"]
    district: str = Field(..., min_length=1, max_length=80)
    state: str = Field("Karnataka", min_length=1, max_length=80)


class OTPVerifyRequest(BaseModel):
    """
    Body for POST /auth/verify-otp (SIGNUP OTP).

    NOTE on naming: this class is `OTPVerifyRequest` (capital OTP). The
    pickup-handoff verification uses a separate class named
    `OtpVerifyRequest` (lowercase tp). They share the word "OTP" but
    nothing else — different storage, different schemas, different
    purpose.

    Carries the full signup payload so the account can be created in one
    round-trip after the OTP is confirmed.
    """
    email: EmailStr
    otp: str = Field(..., min_length=4, max_length=8)
    full_name: str = Field(..., min_length=1, max_length=120)
    password: str = Field(..., min_length=6, max_length=128)
    role: Literal["FARMER", "RIDER"]
    district: str = Field(..., min_length=1, max_length=80)
    state: str = Field("Karnataka", min_length=1, max_length=80)


class UserLogin(BaseModel):
    """
    Body for POST /auth/login.

    Deliberately does NOT enforce a password-length minimum — the server
    is checking a stored hash, not setting one.
    """
    email: EmailStr
    password: str = Field(..., min_length=1, max_length=128)


class ForgotPasswordRequest(BaseModel):
    """
    Body for POST /auth/forgot-password.

    Only the email is required; the server looks up the user, generates a
    short-lived reset code, and (when real email OTP is enabled) mails it.
    """
    email: EmailStr


class ResetPasswordRequest(BaseModel):
    """
    Body for POST /auth/reset-password.

    `otp` is checked against the code issued by /auth/forgot-password (when
    ENABLE_REAL_EMAIL_OTP is True). On success the user's `password_hash`
    column is overwritten with a fresh bcrypt hash of `new_password`.
    """
    email: EmailStr
    otp: str = Field(..., min_length=4, max_length=8)
    new_password: str = Field(..., min_length=6, max_length=128)


class Token(BaseModel):
    """Response for POST /auth/verify-otp and POST /auth/login."""
    access_token: str
    token_type: Literal["bearer"] = "bearer"
    user: UserOut


# ---------------------------------------------------------------------------
# Farmer Account schemas
# ---------------------------------------------------------------------------

class FarmerAccountOut(BaseModel):
    """
    Full farmer account payload. Returned by GET /farmer/account and by
    every PUT below, so the client always receives the complete updated
    record in one response and can refresh its local copy without a
    follow-up GET.

    Email is typed as `str` rather than `EmailStr` on purpose: legacy
    phone-only accounts get an auto-generated address ending in
    `@legacy.kisanrider.local`, and Pydantic's strict EmailStr validation
    rejects `.local` as a non-public TLD. `str` avoids a 500 on those rows.
    """
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    full_name: str
    email: str
    role: Literal["FARMER", "RIDER"]
    is_verified: bool = True

    # Basic info
    district: Optional[str] = None
    taluk_village: Optional[str] = None
    state: Optional[str] = None

    # Farm info
    farm_size_acres: Optional[float] = None
    primary_crops: Optional[str] = None

    # Address
    farm_address: Optional[str] = None
    landmark: Optional[str] = None

    # Payout info
    bank_name: Optional[str] = None
    account_number: Optional[str] = None
    ifsc_code: Optional[str] = None
    upi_id: Optional[str] = None

    # Preferences
    preferred_language: str = "en"


class FarmerProfileUpdate(BaseModel):
    """
    Body for PUT /farmer/profile.

    Every field is optional. The endpoint uses `model_dump(exclude_unset=True)`,
    so only fields the client actually sent are written — omitting a field
    leaves the stored value untouched, while sending it as `null` clears it.
    """
    full_name: Optional[str] = Field(None, min_length=1, max_length=120)
    district: Optional[str] = Field(None, max_length=80)
    taluk_village: Optional[str] = Field(None, max_length=120)


class FarmDetailsUpdate(BaseModel):
    """Body for PUT /farmer/farm-details."""
    farm_size_acres: Optional[float] = Field(
        None, ge=0, le=100000,
        description="Farm size in acres; must be non-negative.",
    )
    primary_crops: Optional[str] = Field(None, max_length=255)


class FarmAddressUpdate(BaseModel):
    """Body for PUT /farmer/address."""
    farm_address: Optional[str] = Field(None, max_length=1000)
    landmark: Optional[str] = Field(None, max_length=255)


class PayoutDetailsUpdate(BaseModel):
    """
    Body for PUT /farmer/payouts.

    All fields are free-text and stored as-is. `ifsc_code` and `upi_id`
    are shape-checked lightly so obviously wrong input is rejected early;
    a full bank/UPI verification flow is out of scope for the MVP.
    """
    bank_name: Optional[str] = Field(None, max_length=100)
    account_number: Optional[str] = Field(None, max_length=30)
    ifsc_code: Optional[str] = Field(None, max_length=20)
    upi_id: Optional[str] = Field(None, max_length=100)

    @field_validator("ifsc_code")
    @classmethod
    def ifsc_uppercase(cls, v: Optional[str]) -> Optional[str]:
        """
        IFSC codes are officially uppercase 11-char strings (4 letters +
        '0' + 6 alphanumerics). We don't enforce the full pattern here —
        users paste with spaces and varied casing, and rejecting a valid
        code because of a stray space is worse than storing it as-is. We
        do normalize to uppercase so lookups remain consistent.
        """
        if v is None:
            return None
        cleaned = v.strip().upper()
        return cleaned or None

    @field_validator("upi_id")
    @classmethod
    def upi_lowercase(cls, v: Optional[str]) -> Optional[str]:
        """UPI IDs are case-insensitive in practice; normalize to lowercase."""
        if v is None:
            return None
        cleaned = v.strip().lower()
        return cleaned or None

    @field_validator("account_number")
    @classmethod
    def account_digits(cls, v: Optional[str]) -> Optional[str]:
        """
        Reject anything containing non-digit characters. Indian bank
        account numbers are digits-only; spaces are stripped first so
        pasting "1234 5678 9012" doesn't fail validation.
        """
        if v is None:
            return None
        cleaned = v.replace(" ", "").strip()
        if not cleaned:
            return None
        if not cleaned.isdigit():
            raise ValueError("account_number must contain digits only")
        return cleaned


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
        None, max_length=255,
        description="Free-text dropoff address/landmark (MVP)",
    )
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
    """Body for POST /produce-requests/{request_id}/verify-otp (pickup handoff)."""
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
    via POST /trips/accept and is never transitioned back into it.
    """
    status: Literal["PICKED_UP", "DELIVERED", "CANCELLED"]
    distance_km: Optional[float] = Field(
        None, gt=0, le=1000,
        description="Trip distance, only used when status is DELIVERED.",
    )


class ActiveTripResponse(TripResponse):
    """Response for GET /trips/active, with the ProduceRequest nested."""
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

    `pickup_otp` is only exposed to the farmer who owns the request.
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
    trip_id: UUID
    distance_km: float = Field(..., gt=0, description="Distance covered for this trip, in kilometers")
    rate_per_kg: float = Field(
        40.0, gt=0,
        description="Mandi rate per kg for the crop, in ₹. Defaults to a placeholder.",
    )


class SettlementResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    trip_id: UUID
    rider_id: Optional[UUID] = None
    farmer_id: Optional[UUID] = None

    base_fare: float
    distance_fare: float
    weight_surcharge: float
    total_payout: float

    crop_name: Optional[str] = None
    quantity_kg: Optional[float] = None
    gross_amount: Optional[float] = None
    rider_fare: Optional[float] = None
    platform_fee: Optional[float] = None
    net_payout: Optional[float] = None

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