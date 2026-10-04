"""
Pydantic validation schemas for KisanRider.

Design note: PostGIS geometry columns (GeoAlchemy2 WKBElement) are never
exposed directly over the API. Inbound requests take plain latitude/longitude
floats; outbound responses are built explicitly in crud.py (via
`shape.to_shape(...)`) into plain floats, then validated against
ProduceRequestResponse.
"""

from datetime import datetime
from typing import Annotated, Literal, Optional
from uuid import UUID

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    EmailStr,
    Field,
    field_validator,
)


# ---------------------------------------------------------------------------
# Shared validators / annotated types
# ---------------------------------------------------------------------------

def _normalize_phone_number(v: Optional[str]) -> Optional[str]:
    """
    Normalize an Indian mobile number to exactly 10 digits, or None.

    Input shapes accepted (all map to "9876543210"):
      - "+91 98765 43210"
      - "+919876543210"
      - "098765-43210"
      - "98765 43210"
      - "9876543210"

    Empty/whitespace input becomes None (clears the field). Anything that
    isn't 10 digits after stripping raises — the caller sees a clear
    validation error rather than a silently-corrupted stored value.

    The validator is deliberately loose about the *input* format (users
    type phone numbers in every conceivable shape) and strict about the
    *output* format (consistent 10-digit storage). This is the same
    philosophy as the IFSC and account-number validators on the payout
    schemas.

    If you later need to support non-Indian numbers, relax the
    `len(cleaned) != 10` check — everything before that is generic
    country-code stripping.
    """
    if v is None:
        return None

    # Strip formatting characters that are never part of the number.
    cleaned = v.replace(" ", "").replace("-", "").strip()
    if not cleaned:
        return None

    # Strip optional country code / trunk prefix. Order matters: check
    # "+91" before bare "91" so "+91..." is handled by the first branch.
    if cleaned.startswith("+91"):
        cleaned = cleaned[3:]
    elif len(cleaned) == 12 and cleaned.startswith("91"):
        cleaned = cleaned[2:]
    elif len(cleaned) == 11 and cleaned.startswith("0"):
        cleaned = cleaned[1:]

    if not cleaned.isdigit() or len(cleaned) != 10:
        raise ValueError(
            "phone_number must be a 10-digit mobile number "
            "(optionally prefixed with +91)"
        )

    return cleaned


# Reusable annotated type — reference this in every schema that carries
# a phone number so validation and normalization stay in one place.
PhoneNumber = Annotated[Optional[str], AfterValidator(_normalize_phone_number)]


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

    `phone_number` is the contact number editable from the Account
    screens. The legacy `phone` login identifier is intentionally not
    exposed here — it's an internal implementation detail.
    """
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    full_name: str
    email: str
    role: Literal["FARMER", "RIDER"]
    state: Optional[str] = None
    district: Optional[str] = None
    phone_number: Optional[str] = None
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
    phone_number: Optional[str] = None
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

    `phone_number` is normalized to 10 digits by the shared `PhoneNumber`
    annotated type. Sending an empty string clears the field to None.
    """
    full_name: Optional[str] = Field(None, min_length=1, max_length=120)
    district: Optional[str] = Field(None, max_length=80)
    taluk_village: Optional[str] = Field(None, max_length=120)
    phone_number: PhoneNumber = None


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
# Rider Account schemas
# ---------------------------------------------------------------------------

class RiderAccountOut(BaseModel):
    """
    Full rider account payload. Returned by GET /rider/account and by every
    PUT/PATCH below, so the client always gets the complete updated record
    in one response.

    Mirrors FarmerAccountOut's shape decisions:
      - `email` is `str`, not `EmailStr`, so legacy phone-only accounts
        (whose synthetic address ends in `.local`) don't 500 on validation.
      - Every rider-specific field is Optional. A rider who signed up five
        seconds ago has none of them set, and the client renders empty
        states for each section until they do.
    """
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    full_name: str
    email: str
    role: Literal["FARMER", "RIDER"]
    phone_number: Optional[str] = None
    is_verified: bool = True

    # Basic info
    district: Optional[str] = None
    state: Optional[str] = None

    # Duty status
    is_on_duty: bool = False

    # Driver & vehicle info
    license_number: Optional[str] = None
    vehicle_type: Optional[str] = None
    vehicle_number: Optional[str] = None
    payload_capacity_kg: Optional[float] = None

    # Preferred routes
    operating_routes: Optional[str] = None

    # Payout info
    bank_name: Optional[str] = None
    account_number: Optional[str] = None
    ifsc_code: Optional[str] = None
    upi_id: Optional[str] = None

    # Preferences
    preferred_language: str = "en"


class RiderProfileUpdate(BaseModel):
    """
    Body for PUT /rider/profile.

    Only name, district, and contact phone — email changes go through the
    OTP flow (same reasoning as the farmer endpoint), and `state` is fixed
    at Karnataka for the MVP.

    `phone_number` is normalized to 10 digits by the shared `PhoneNumber`
    annotated type.
    """
    full_name: Optional[str] = Field(None, min_length=1, max_length=120)
    district: Optional[str] = Field(None, max_length=80)
    phone_number: PhoneNumber = None


class VehicleDetailsUpdate(BaseModel):
    """
    Body for PUT /rider/vehicle-details.

    Validators normalize the two fields most prone to formatting drift:
    license_number (uppercase, digits+letters only) and vehicle_number
    (uppercase, spaces stripped). Users paste these with arbitrary casing
    and spaces; rejecting valid input over a stray space is a worse UX
    than storing it consistently uppercase.
    """
    license_number: Optional[str] = Field(None, max_length=30)
    vehicle_type: Optional[str] = Field(None, max_length=80)
    vehicle_number: Optional[str] = Field(None, max_length=20)
    payload_capacity_kg: Optional[float] = Field(
        None, ge=0, le=100000,
        description="Vehicle payload capacity in kilograms.",
    )

    @field_validator("license_number")
    @classmethod
    def license_uppercase(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        # Strip spaces and hyphens that users paste in from the physical
        # card ("KA-01 2019 0001234"), then uppercase.
        cleaned = v.replace(" ", "").replace("-", "").strip().upper()
        return cleaned or None

    @field_validator("vehicle_number")
    @classmethod
    def vehicle_number_normalize(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        cleaned = v.replace(" ", "").replace("-", "").strip().upper()
        return cleaned or None

    @field_validator("vehicle_type")
    @classmethod
    def vehicle_type_trim(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        cleaned = v.strip()
        return cleaned or None


class RiderRoutesUpdate(BaseModel):
    """
    Body for PUT /rider/routes.

    `operating_routes` is a comma-separated list of districts/regions the
    rider is willing to serve, e.g. "Kolar, Bengaluru Urban, Tumakuru".
    Stored as a single string; the client splits/joins as needed.
    """
    operating_routes: Optional[str] = Field(
        None, max_length=255,
        description="Comma-separated list of operating districts/regions.",
    )

    @field_validator("operating_routes")
    @classmethod
    def routes_trim(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        # Normalize to "a, b, c" — consistent spacing, no empties.
        parts = [p.strip() for p in v.split(",")]
        joined = ", ".join(p for p in parts if p)
        return joined or None


class RiderPayoutUpdate(BaseModel):
    """
    Body for PUT /rider/payouts.

    Same shape and validators as the farmer's PayoutDetailsUpdate, but
    kept as its own class so the two endpoints can evolve independently
    (e.g. if riders later need a settlement account separate from a
    farmer's payout account).
    """
    bank_name: Optional[str] = Field(None, max_length=100)
    account_number: Optional[str] = Field(None, max_length=30)
    ifsc_code: Optional[str] = Field(None, max_length=20)
    upi_id: Optional[str] = Field(None, max_length=100)

    @field_validator("ifsc_code")
    @classmethod
    def ifsc_uppercase(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        cleaned = v.strip().upper()
        return cleaned or None

    @field_validator("upi_id")
    @classmethod
    def upi_lowercase(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        cleaned = v.strip().lower()
        return cleaned or None

    @field_validator("account_number")
    @classmethod
    def account_digits(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        cleaned = v.replace(" ", "").strip()
        if not cleaned:
            return None
        if not cleaned.isdigit():
            raise ValueError("account_number must contain digits only")
        return cleaned


class DutyStatusUpdate(BaseModel):
    """
    Body for PATCH /rider/duty-status.

    `is_on_duty` is required (not Optional). The client is explicitly
    setting a state, not optionally editing a field — a PATCH with an
    absent `is_on_duty` is a client bug, not a partial update.
    """
    is_on_duty: bool = Field(
        ...,
        description="True = online and accepting trips; False = offline.",
    )


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
    """
    LEGACY response for GET /trips/active.

    Kept for backward compatibility with older clients. New code should
    use [TripActiveOut], which carries privacy-aware contact fields in a
    flat shape and is what /trips/active now returns.
    """
    produce_request: ProduceRequestResponse


# ---------------------------------------------------------------------------
# Privacy-aware trip views
# ---------------------------------------------------------------------------

class TripAvailableOut(BaseModel):
    """
    An unaccepted trip shown to riders browsing the nearby feed.

    Farmer contact information is deliberately withheld until the rider
    accepts: circulating a phone number to every rider in a 50 km radius
    is both a privacy problem and a harassment vector. Only the farmer's
    first name is included, so the rider has a human reference without an
    identifier they can misuse.

    ## Naming

    `trip_id` here is the ProduceRequest's id in the current data model —
    a Trip row only exists *after* a rider accepts. The rider-facing
    client receives `trip_id` from this endpoint and passes it back to
    `POST /trips/{trip_id}/accept`, which treats it as the ProduceRequest
    id. The mapping is transparent to consumers.
    """
    trip_id: UUID
    crop_type: str
    crate_count: int
    weight_kg: float
    latitude: float
    longitude: float
    pickup_district: Optional[str] = None
    pickup_locality: Optional[str] = None

    # Estimated rider payout. Computed from the settlement formula using
    # the default distance assumption — the authoritative number is
    # calculated when the trip is marked delivered with a real distance.
    payout_amount: float

    status: Literal["PENDING"] = "PENDING"

    # Farmer identity — phone is always null pre-acceptance; name is
    # first-name only. See class docstring.
    farmer_full_name: Optional[str] = None
    farmer_phone_number: Optional[str] = None


class TripActiveOut(BaseModel):
    """
    An accepted (or completed) trip shared with the assigned rider and
    the owning farmer.

    Both sides' contact info is exposed once a rider is assigned — the
    rider needs the farmer's number to coordinate the pickup, and the
    farmer needs the rider's number to track and receive the delivery.
    Before assignment (order still PENDING), the rider fields are null
    and the farmer's contact info is withheld from everyone (the farmer
    already knows their own number; the rider isn't yet party to the
    deal).

    ## Status values

    `status` is typed as `str` rather than a `Literal` because the model
    carries trip statuses (ACCEPTED, PICKED_UP, DELIVERED, CANCELLED) and
    ProduceRequest statuses (PENDING) through the same field, and new
    states may be added. Clients should pattern-match on the values they
    care about.
    """
    trip_id: UUID
    produce_request_id: UUID
    status: str

    crop_type: str
    crate_count: int
    weight_kg: float
    latitude: float
    longitude: float

    pickup_address: Optional[str] = None
    dropoff_address: Optional[str] = None
    dropoff_lat: Optional[float] = None
    dropoff_lng: Optional[float] = None

    # Contact & vehicle — null until a rider is assigned. See docstring.
    farmer_full_name: Optional[str] = None
    farmer_phone_number: Optional[str] = None
    rider_full_name: Optional[str] = None
    rider_phone_number: Optional[str] = None
    vehicle_number: Optional[str] = None
    vehicle_type: Optional[str] = None


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