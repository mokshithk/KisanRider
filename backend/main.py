"""
KisanRider FastAPI application.
"""

# --- Env / dotenv bootstrap (must run before anything reads os.environ) ---
from dotenv import load_dotenv
load_dotenv()

import math
import os
import random  # noqa: F401  (kept for parity with downstream modules)
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import List, Optional
from uuid import UUID

import httpx
from fastapi import Depends, FastAPI, File, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

import auth
import config
import crud
import models
import otp_service
import schemas
from database import engine, get_db


# Temporary startup diagnostics — remove once you've confirmed both are set.
print(f"[startup] DATA_GOV_API_KEY present: {bool(os.environ.get('DATA_GOV_API_KEY'))}")
print(f"[startup] ENABLE_REAL_EMAIL_OTP = {config.ENABLE_REAL_EMAIL_OTP}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Create any tables defined in models.py that don't exist yet in Postgres
    (e.g. crate_scans) on startup.

    create_all() only issues CREATE TABLE IF NOT EXISTS for tables it
    doesn't find — it never alters an existing table. New columns on the
    `users` table (both the farmer-account set and the rider-account set)
    must be applied to an existing database with a manual ALTER TABLE.
    See the migration snippets in the Farmer Account and Rider Account
    sections below.

    Farmer account migration:

        ALTER TABLE users
          ADD COLUMN IF NOT EXISTS taluk_village      VARCHAR(120),
          ADD COLUMN IF NOT EXISTS farm_size_acres    DOUBLE PRECISION,
          ADD COLUMN IF NOT EXISTS primary_crops      VARCHAR(255),
          ADD COLUMN IF NOT EXISTS farm_address       TEXT,
          ADD COLUMN IF NOT EXISTS landmark           VARCHAR(255),
          ADD COLUMN IF NOT EXISTS bank_name          VARCHAR(100),
          ADD COLUMN IF NOT EXISTS account_number     VARCHAR(30),
          ADD COLUMN IF NOT EXISTS ifsc_code          VARCHAR(20),
          ADD COLUMN IF NOT EXISTS upi_id             VARCHAR(100),
          ADD COLUMN IF NOT EXISTS preferred_language VARCHAR(10)
            NOT NULL DEFAULT 'en';

    Rider account migration:

        ALTER TABLE users
          ADD COLUMN IF NOT EXISTS is_on_duty          BOOLEAN
            NOT NULL DEFAULT FALSE,
          ADD COLUMN IF NOT EXISTS license_number      VARCHAR(30),
          ADD COLUMN IF NOT EXISTS vehicle_type        VARCHAR(80),
          ADD COLUMN IF NOT EXISTS vehicle_number      VARCHAR(20),
          ADD COLUMN IF NOT EXISTS payload_capacity_kg DOUBLE PRECISION,
          ADD COLUMN IF NOT EXISTS operating_routes    VARCHAR(255);
    """
    models.Base.metadata.create_all(bind=engine)
    yield


app = FastAPI(title="KisanRider API", lifespan=lifespan)

# Allows Flutter Web on any local port to interact with FastAPI
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Local static storage for delivery photos.
UPLOAD_DIR = Path("static/uploads")
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory="static"), name="static")

ALLOWED_UPLOAD_CONTENT_TYPES = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
}
MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB


# ---------------------------------------------------------------------------
# Health / diagnostics
# ---------------------------------------------------------------------------

@app.get("/db-check")
def db_check(db: Session = Depends(get_db)):
    try:
        result = db.execute(text("SELECT PostGIS_Version();")).fetchone()
        return {"database": "Connected", "postgis_version": result[0]}
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Database connection failed: {str(e)}",
        )


# ---------------------------------------------------------------------------
# Mandi search (OpenStreetMap Overpass API — no API key required)
# ---------------------------------------------------------------------------

_DISTRICT_CENTERS: dict[str, tuple[float, float]] = {
    "Bagalkot":           (16.1817, 75.6958),
    "Ballari":            (15.1394, 76.9214),
    "Belagavi":           (15.8497, 74.4977),
    "Bengaluru Rural":    (13.1500, 77.4000),
    "Bengaluru Urban":    (12.9716, 77.5946),
    "Bidar":              (17.9104, 77.5199),
    "Chamarajanagar":     (11.9261, 76.9437),
    "Chikkaballapura":    (13.4355, 77.7315),
    "Chikkamagaluru":     (13.3161, 75.7720),
    "Chitradurga":        (14.2251, 76.3980),
    "Dakshina Kannada":   (12.9141, 74.8560),
    "Davanagere":         (14.4644, 75.9218),
    "Dharwad":            (15.4589, 75.0078),
    "Gadag":              (15.4166, 75.6167),
    "Hassan":             (13.0071, 76.0962),
    "Haveri":             (14.7935, 75.4040),
    "Kalaburagi":         (17.3297, 76.8343),
    "Kodagu":             (12.4244, 75.7382),
    "Kolar":              (13.1362, 78.1291),
    "Koppal":             (15.3510, 76.1550),
    "Mandya":             (12.5223, 76.8954),
    "Mysuru":             (12.2958, 76.6394),
    "Raichur":            (16.2076, 77.3463),
    "Ramanagara":         (12.7216, 77.2801),
    "Shivamogga":         (13.9299, 75.5681),
    "Tumakuru":           (13.3392, 77.1140),
    "Udupi":              (13.3409, 74.7421),
    "Uttara Kannada":     (14.8050, 74.6300),
    "Vijayapura":         (16.8302, 75.7100),
    "Yadgir":             (16.7700, 77.1400),
    "Vijayanagara":       (15.2689, 76.3909),
}

_OVERPASS_MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
_OVERPASS_USER_AGENT = "KisanRiderApp/1.0"

_MANDI_CACHE: dict[str, tuple[float, list[dict]]] = {}
_MANDI_CACHE_TTL = 3600  # seconds

_MANDI_BLACKLIST = [
    "mandir", "mandira", "temple", "vidya", "kalamandir",
    "showroom", "school", "college", "church", "hospital",
]


def _bbox_around(
    lat: float, lng: float, radius_km: float
) -> tuple[float, float, float, float]:
    """Return (south, west, north, east) for a square bbox."""
    lat_delta = radius_km / 111.0
    lng_delta = radius_km / (111.0 * math.cos(math.radians(lat)))
    return (lat - lat_delta, lng - lng_delta, lat + lat_delta, lng + lng_delta)


@app.get("/mandis/search")
async def search_mandis(
    district: str = Query(..., min_length=1, max_length=80),
):
    """
    Find APMC mandis / market yards in a district via OpenStreetMap's
    Overpass API (free, no API key).
    """
    district_clean = district.strip()
    center = _DISTRICT_CENTERS.get(district_clean)
    if center is None:
        raise HTTPException(status_code=400, detail=f"Unknown district: {district_clean}")

    cache_key = district_clean.lower()
    now = time.time()
    cached = _MANDI_CACHE.get(cache_key)
    if cached and (now - cached[0]) < _MANDI_CACHE_TTL:
        return {"district": district_clean, "mandis": cached[1]}

    lat, lng = center
    south, west, north, east = _bbox_around(lat, lng, radius_km=30.0)
    bbox = f"{south},{west},{north},{east}"

    overpass_query = f"""
    [out:json][timeout:60];
    (
      nwr["amenity"="marketplace"]({bbox});
      nwr["name"~"\\b(APMC|Mandi)\\b",i]({bbox});
    );
    out center tags;
    """

    raw: dict | None = None
    last_error: str | None = None
    async with httpx.AsyncClient(timeout=90.0) as client:
        for mirror in _OVERPASS_MIRRORS:
            try:
                resp = await client.post(
                    mirror,
                    data={"data": overpass_query},
                    headers={"User-Agent": _OVERPASS_USER_AGENT},
                )
                resp.raise_for_status()
                raw = resp.json()
                break
            except httpx.HTTPError as e:
                last_error = f"{mirror}: {e}"
                continue

    if raw is None:
        raise HTTPException(
            status_code=502,
            detail=f"All Overpass mirrors failed. Last error: {last_error}",
        )

    mandis: list[dict] = []
    for el in raw.get("elements", []):
        tags = el.get("tags", {}) or {}
        name = tags.get("name") or tags.get("name:en")
        if not name:
            continue

        if el.get("type") == "node":
            el_lat = el.get("lat")
            el_lng = el.get("lon")
        else:
            c = el.get("center") or {}
            el_lat = c.get("lat")
            el_lng = c.get("lon")

        if el_lat is None or el_lng is None:
            continue

        addr_parts = [
            tags.get("addr:street"),
            tags.get("addr:city"),
            tags.get("addr:district"),
            tags.get("addr:state"),
        ]
        address = ", ".join(p for p in addr_parts if p) or name

        haystack = f"{name} {address}".lower()
        if any(term in haystack for term in _MANDI_BLACKLIST):
            continue

        mandis.append({
            "name": name,
            "address": address,
            "lat": float(el_lat),
            "lng": float(el_lng),
        })

    seen = set()
    unique: list[dict] = []
    for m in mandis:
        key = (m["name"], round(m["lat"], 4), round(m["lng"], 4))
        if key in seen:
            continue
        seen.add(key)
        unique.append(m)

    _MANDI_CACHE[cache_key] = (now, unique)

    return {"district": district_clean, "mandis": unique}


# ---------------------------------------------------------------------------
# Mandi rates (Data.gov.in Agmarknet — optional API key, mock fallback)
# ---------------------------------------------------------------------------

_DATA_GOV_BASE_URL = (
    "https://api.data.gov.in/resource/9ef84268-d588-465a-a308-a864a43d0070"
)

_MANDI_RATE_DISTRICTS = [
    "Kolar",
    "Bengaluru Urban",
    "Mandya",
    "Belagavi",
    "Davanagere",
]

_MOCK_MANDI_RATES: dict[str, list[dict]] = {
    "Kolar": [
        {"crop": "Tomato",  "modal_price": 2200, "mandi": "Kolar APMC"},
        {"crop": "Onion",   "modal_price": 2800, "mandi": "Kolar APMC"},
        {"crop": "Potato",  "modal_price": 1900, "mandi": "Bangarpet APMC"},
        {"crop": "Beans",   "modal_price": 3400, "mandi": "Chintamani APMC"},
    ],
    "Bengaluru Urban": [
        {"crop": "Tomato",  "modal_price": 2100, "mandi": "Yeshwanthpur APMC"},
        {"crop": "Carrot",  "modal_price": 3000, "mandi": "Yeshwanthpur APMC"},
        {"crop": "Beans",   "modal_price": 3600, "mandi": "Binny Mill APMC"},
        {"crop": "Onion",   "modal_price": 2600, "mandi": "Binny Mill APMC"},
    ],
    "Mandya": [
        {"crop": "Sugarcane", "modal_price": 320, "mandi": "Mandya APMC"},
        {"crop": "Ragi",      "modal_price": 3300, "mandi": "Mandya APMC"},
        {"crop": "Paddy",     "modal_price": 2200, "mandi": "Maddur APMC"},
        {"crop": "Coconut",   "modal_price": 1800, "mandi": "Maddur APMC"},
    ],
    "Belagavi": [
        {"crop": "Sugarcane", "modal_price": 310, "mandi": "Belagavi APMC"},
        {"crop": "Maize",     "modal_price": 1950, "mandi": "Belagavi APMC"},
        {"crop": "Soybean",   "modal_price": 4300, "mandi": "Bailhongal APMC"},
        {"crop": "Onion",     "modal_price": 2700, "mandi": "Bailhongal APMC"},
    ],
    "Davanagere": [
        {"crop": "Maize",     "modal_price": 2000, "mandi": "Davanagere APMC"},
        {"crop": "Paddy",     "modal_price": 2300, "mandi": "Davanagere APMC"},
        {"crop": "Cotton",    "modal_price": 6800, "mandi": "Harihar APMC"},
        {"crop": "Sunflower", "modal_price": 6000, "mandi": "Harihar APMC"},
    ],
}


def _mock_rates_for(district: str) -> list[dict]:
    chosen = _MOCK_MANDI_RATES.get(district) or _MOCK_MANDI_RATES["Kolar"]
    return [
        {
            "crop": r["crop"],
            "modal_price": f"₹{r['modal_price']} / Qtl",
            "mandi": r["mandi"],
        }
        for r in chosen
    ]


@app.get("/mandi-rates/")
async def get_mandi_rates(
    district: Optional[str] = Query(None, max_length=80),
):
    """
    Today's modal mandi prices for a Karnataka district.

    Tries Data.gov.in's Agmarknet resource first when DATA_GOV_API_KEY is
    set; falls back to a small local mock dataset on any failure.
    """
    selected_district = (district or "Kolar").strip()

    api_key = os.environ.get("DATA_GOV_API_KEY")
    rates: list[dict] | None = None

    if api_key:
        try:
            async with httpx.AsyncClient(timeout=25.0) as client:
                resp = await client.get(
                    _DATA_GOV_BASE_URL,
                    params={
                        "api-key": api_key,
                        "format": "json",
                        "limit": 100,
                        "filters[state.keyword]": "Karnataka",
                        "filters[district]": selected_district,
                    },
                    headers={"User-Agent": _OVERPASS_USER_AGENT},
                )
                print(f"[mandi-rates] filtered status={resp.status_code}")
                resp.raise_for_status()
                payload = resp.json()
                print(
                    f"[mandi-rates] filtered total={payload.get('total')} "
                    f"count={payload.get('count')} "
                    f"records={len(payload.get('records', []))}"
                )

                records = (
                    payload.get("records")
                    if isinstance(payload, dict)
                    else None
                )

                if not records:
                    print("[mandi-rates] filtered returned nothing, retrying unfiltered...")
                    resp2 = await client.get(
                        _DATA_GOV_BASE_URL,
                        params={
                            "api-key": api_key,
                            "format": "json",
                            "limit": 200,
                        },
                        headers={"User-Agent": _OVERPASS_USER_AGENT},
                    )
                    print(f"[mandi-rates] unfiltered status={resp2.status_code}")
                    resp2.raise_for_status()
                    payload2 = resp2.json()
                    all_records = (
                        payload2.get("records", [])
                        if isinstance(payload2, dict)
                        else []
                    )
                    print(f"[mandi-rates] unfiltered total records={len(all_records)}")

                    def _field(rec, *names):
                        for n in names:
                            v = rec.get(n)
                            if v:
                                return str(v).strip().lower()
                        return ""

                    records = [
                        r for r in all_records
                        if _field(r, "state", "State") == "karnataka"
                        and _field(r, "district", "District")
                        == selected_district.lower()
                    ]
                    print(f"[mandi-rates] client-side filtered to {len(records)} rows")

            if records:
                parsed: list[dict] = []
                for rec in records:
                    commodity = rec.get("commodity") or rec.get("Commodity")
                    modal = rec.get("modal_price") or rec.get("Modal_Price")
                    market = rec.get("market") or rec.get("Market")

                    if not commodity or not modal or not market:
                        continue
                    try:
                        modal_val = float(modal)
                    except (TypeError, ValueError):
                        continue
                    if modal_val <= 0:
                        continue

                    parsed.append({
                        "crop": str(commodity).strip(),
                        "modal_price": f"₹{int(modal_val)} / Qtl",
                        "mandi": str(market).strip(),
                    })

                if parsed:
                    rates = parsed
        except httpx.HTTPError as e:
            print(f"[mandi-rates] HTTP error: {type(e).__name__}: {e}")
            if hasattr(e, "response") and e.response is not None:
                print(f"[mandi-rates] response body: {e.response.text[:500]}")
            rates = None
        except Exception as e:
            print(f"[mandi-rates] unexpected error: {type(e).__name__}: {e}")
            rates = None

    if not rates:
        rates = _mock_rates_for(selected_district)
        source = "mock"
    else:
        source = "live"

    return {
        "status": "success",
        "source": source,
        "selected_district": selected_district,
        "available_districts": _MANDI_RATE_DISTRICTS,
        "rates": rates,
    }


# ---------------------------------------------------------------------------
# Signup + OTP (real email when ENABLE_REAL_EMAIL_OTP, dev bypass otherwise)
# ---------------------------------------------------------------------------

@app.post("/auth/signup")
def signup(payload: schemas.UserSignUp, db: Session = Depends(get_db)):
    """
    Step 1 of the signup flow: validate the email, generate an OTP, and
    (when real OTP is enabled) email it.

    Returns immediately with "OTP sent to your email" on the happy path.
    When ENABLE_REAL_EMAIL_OTP is False, returns the bypass message and
    does NOT attempt delivery.

    The email is only checked for uniqueness here — the user row is not
    created until /auth/verify-otp succeeds.
    """
    if crud.get_user_by_email(db, payload.email):
        raise HTTPException(status_code=400, detail="Email already registered")

    result = otp_service.issue_and_send_email_otp(payload.email)

    if result["bypass"]:
        return {"message": "Bypass active. Enter any 4 digits to continue"}

    if not result["sent"]:
        raise HTTPException(
            status_code=502,
            detail="Could not send OTP email. Please try again later.",
        )

    return {"message": "OTP sent to your email"}


@app.post("/auth/verify-otp", response_model=schemas.Token)
def verify_signup_otp(
    payload: schemas.OTPVerifyRequest,
    db: Session = Depends(get_db),
):
    """
    Step 2 of the signup flow: verify the OTP and create the account.

    When ENABLE_REAL_EMAIL_OTP is True, the submitted OTP is checked
    against the stored code (5-minute TTL, single-use). When False, the
    check is skipped; any 4–8 digit string is accepted.

    On success, returns a JWT plus the new user's public profile.
    """
    if crud.get_user_by_email(db, payload.email):
        raise HTTPException(status_code=400, detail="Email already registered")

    if config.ENABLE_REAL_EMAIL_OTP:
        if not otp_service.verify_email_otp_code(payload.email, payload.otp):
            raise HTTPException(status_code=400, detail="Invalid or expired OTP")
    else:
        # Dev bypass — still sanity-check shape so a client bug can't
        # create a user with an empty or malformed code field.
        otp = payload.otp.strip()
        if not otp.isdigit() or not (4 <= len(otp) <= 8):
            raise HTTPException(
                status_code=400,
                detail="Dev bypass active — enter any 4 to 8 digits.",
            )

    try:
        user = crud.create_user_signup(
            db,
            email=payload.email,
            password_hash=auth.hash_password(payload.password),
            role=payload.role,
            full_name=payload.full_name,
            district=payload.district,
            state=payload.state,
        )
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))

    token = auth.create_access_token(user.id)
    return schemas.Token(
        access_token=token,
        token_type="bearer",
        user=schemas.UserOut.model_validate(user),
    )


@app.post("/auth/login", response_model=schemas.Token)
def login(
    payload: schemas.UserLogin,
    db: Session = Depends(get_db),
):
    """
    Standard email + password login.

    Returns the same `Token` shape as /auth/verify-otp so the client can
    treat both auth paths identically.

    All failure modes return the SAME 401 with the same message —
    "Invalid email or password" — deliberately.
    """
    invalid = HTTPException(
        status_code=401,
        detail="Invalid email or password",
    )

    user = crud.get_user_by_email(db, payload.email)
    if not user:
        raise invalid

    if not user.password_hash:
        raise invalid

    try:
        matches = auth.verify_password(payload.password, user.password_hash)
    except Exception:
        matches = False

    if not matches:
        raise invalid

    token = auth.create_access_token(user.id)
    return schemas.Token(
        access_token=token,
        token_type="bearer",
        user=schemas.UserOut.model_validate(user),
    )


# ---------------------------------------------------------------------------
# Password reset via email OTP
# ---------------------------------------------------------------------------

@app.post("/auth/forgot-password")
def forgot_password(
    payload: schemas.ForgotPasswordRequest,
    db: Session = Depends(get_db),
):
    """
    Step 1 of the password reset flow.

    Looks up the email, then either mails a 4-digit reset code (when
    ENABLE_REAL_EMAIL_OTP is True) or returns the dev-bypass message.

    A 404 here leaks whether an email is registered. That's an intentional
    trade-off for MVP UX: the client can tell the user "no account with
    that email" instead of leaving them stuck. If enumeration becomes a
    concern, switch to always returning 200 with the same message — the
    rest of the flow doesn't need to change.
    """
    user = crud.get_user_by_email(db, payload.email)
    if not user:
        raise HTTPException(
            status_code=404,
            detail="User with this email does not exist",
        )

    result = otp_service.issue_and_send_password_reset_otp(payload.email)

    if result["bypass"]:
        return {"message": "Bypass active. Enter any 4 digits to reset password"}

    if not result["sent"]:
        raise HTTPException(
            status_code=502,
            detail="Could not send password reset email. Please try again later.",
        )

    return {"message": "Password reset OTP sent to your email"}


@app.post("/auth/reset-password")
def reset_password(
    payload: schemas.ResetPasswordRequest,
    db: Session = Depends(get_db),
):
    """
    Step 2 of the password reset flow.

    When ENABLE_REAL_EMAIL_OTP is True, the submitted OTP is validated
    against the code cached by /auth/forgot-password (5-minute TTL,
    single-use). When False, the check is skipped, but the shape is still
    sanity-checked so a client bug can't submit an empty code.

    On success, the user's password_hash column is replaced with a fresh
    bcrypt hash of `new_password` and the change is committed.
    """
    user = crud.get_user_by_email(db, payload.email)
    if not user:
        raise HTTPException(
            status_code=404,
            detail="User with this email does not exist",
        )

    if config.ENABLE_REAL_EMAIL_OTP:
        if not otp_service.verify_password_reset_otp_code(
            payload.email, payload.otp
        ):
            raise HTTPException(status_code=400, detail="Invalid or expired OTP")
    else:
        otp = payload.otp.strip()
        if not otp.isdigit() or not (4 <= len(otp) <= 8):
            raise HTTPException(
                status_code=400,
                detail="Dev bypass active — enter any 4 to 8 digits.",
            )

    try:
        crud.update_user_password(
            db, user, auth.hash_password(payload.new_password)
        )
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))

    return {"message": "Password updated successfully"}


# ---------------------------------------------------------------------------
# Dev-only auth (local testing in Swagger UI)
# ---------------------------------------------------------------------------

@app.post("/auth/dev-token")
def issue_dev_token(
    user_id: UUID = Query(..., description="Existing user to mint a test token for"),
    db: Session = Depends(get_db),
):
    """
    Mint a short-lived access token for an existing user, for exercising
    protected endpoints from Swagger UI without going through the normal
    auth flow. 404s in production.
    """
    if not auth.DEV_MODE:
        raise HTTPException(status_code=404, detail="Not found")

    user = crud.get_user_by_id(db, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    token = auth.create_dev_token(user_id)
    return {"access_token": token, "token_type": "bearer"}


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

@app.post("/users/", response_model=schemas.UserResponse, status_code=201)
def register_user(user: schemas.UserCreate, db: Session = Depends(get_db)):
    """Register a new farmer or rider (legacy path — no password, no OTP)."""
    if crud.get_user_by_phone(db, user.phone):
        raise HTTPException(status_code=400, detail="Phone number already registered")

    try:
        return crud.create_user(db, user)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Farmer Account
#
# All four PUTs follow the same shape:
#   - payload.model_dump(exclude_unset=True) so omitted fields are left
#     untouched and explicit nulls clear the stored value;
#   - crud.apply_user_updates commits the change;
#   - the full updated account is returned so the client can refresh its
#     local copy without a follow-up GET.
#
# Every endpoint is gated on role FARMER, so a rider token gets a 403 —
# the schema shape is farmer-specific (farm size, payouts, etc.).
# ---------------------------------------------------------------------------

@app.get(
    "/farmer/account",
    response_model=schemas.FarmerAccountOut,
    summary="Get the logged-in farmer's full account record",
)
def get_farmer_account(
    current_user: models.User = Depends(auth.require_role("FARMER")),
):
    """
    Return every account field the farmer-side UI needs: identity, farm
    info, pickup address, payout details, and preferences. No DB query is
    issued here — `require_role` already resolved the User row via
    `get_current_user`.
    """
    return current_user


@app.put(
    "/farmer/profile",
    response_model=schemas.FarmerAccountOut,
    summary="Update basic profile info (name, district, taluk/village)",
)
def update_farmer_profile(
    payload: schemas.FarmerProfileUpdate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Update the name and location fields.

    `email` is intentionally NOT updatable here. Changing it is a
    privileged operation that needs re-verification via the OTP flow —
    silently accepting a new address would let anyone repoint the account
    at an email they don't control. Add a dedicated endpoint when needed.
    """
    updates = payload.model_dump(exclude_unset=True)

    # Guard against a client sending `{"full_name": ""}` — Pydantic's
    # `min_length=1` only rejects empty strings that are actually
    # present, and "" passes that check if it's stripped to whitespace.
    if "full_name" in updates and updates["full_name"] is not None:
        updates["full_name"] = updates["full_name"].strip()
        if not updates["full_name"]:
            raise HTTPException(
                status_code=400,
                detail="full_name cannot be empty",
            )

    try:
        return crud.apply_user_updates(db, current_user, updates)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.put(
    "/farmer/farm-details",
    response_model=schemas.FarmerAccountOut,
    summary="Update farm size and primary crops",
)
def update_farmer_farm_details(
    payload: schemas.FarmDetailsUpdate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """Update `farm_size_acres` and `primary_crops`."""
    updates = payload.model_dump(exclude_unset=True)

    if "primary_crops" in updates and updates["primary_crops"] is not None:
        updates["primary_crops"] = updates["primary_crops"].strip() or None

    try:
        return crud.apply_user_updates(db, current_user, updates)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.put(
    "/farmer/address",
    response_model=schemas.FarmerAccountOut,
    summary="Update farm pickup address and landmark",
)
def update_farmer_address(
    payload: schemas.FarmAddressUpdate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Update the free-text pickup address and the short landmark line.

    These are display-only fields for the MVP — the actual pickup
    coordinates for a ProduceRequest still come from the client (mocked
    in the current farmer_dashboard.dart). Wiring these strings to
    geocoding is a separate piece of work.
    """
    updates = payload.model_dump(exclude_unset=True)

    for field in ("farm_address", "landmark"):
        if field in updates and updates[field] is not None:
            updates[field] = updates[field].strip() or None

    try:
        return crud.apply_user_updates(db, current_user, updates)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.put(
    "/farmer/payouts",
    response_model=schemas.FarmerAccountOut,
    summary="Update bank account and UPI payout details",
)
def update_farmer_payouts(
    payload: schemas.PayoutDetailsUpdate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Update the farmer's payout destination.

    Values are stored as plain text — no checksum or penny-drop
    verification runs here. `ifsc_code`, `upi_id`, and `account_number`
    are normalized/validated at the schema layer (uppercase IFSC,
    lowercase UPI, digits-only account number with spaces stripped).
    """
    updates = payload.model_dump(exclude_unset=True)

    for field in ("bank_name", "account_number", "ifsc_code", "upi_id"):
        if field in updates and updates[field] is not None:
            updates[field] = updates[field].strip() or None

    try:
        return crud.apply_user_updates(db, current_user, updates)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Rider Account
#
# Mirrors the Farmer Account endpoints, with two differences:
#
#   1. `is_on_duty` is toggled via PATCH rather than PUT. It's a state
#      transition the client performs with a single explicit boolean, not
#      a partial update of a record — PUT semantics would be misleading.
#
#   2. Every endpoint is gated on role RIDER, so a farmer token gets a 403.
#      The RiderAccountOut shape carries vehicle/license fields a farmer
#      has no use for.
#
# As with the farmer endpoints, all updates use
# `payload.model_dump(exclude_unset=True)` so omitted fields stay as
# stored and explicit nulls clear, and every response returns the full
# updated account record.
# ---------------------------------------------------------------------------

@app.get(
    "/rider/account",
    response_model=schemas.RiderAccountOut,
    summary="Get the logged-in rider's full account record",
)
def get_rider_account(
    current_user: models.User = Depends(auth.require_role("RIDER")),
):
    """
    Return every account field the rider-side UI needs: identity, duty
    status, vehicle details, operating routes, payout info, and
    preferences. No DB query is issued here — `require_role` already
    resolved the User row via `get_current_user`.
    """
    return current_user


@app.patch(
    "/rider/duty-status",
    response_model=schemas.RiderAccountOut,
    summary="Toggle the rider's online/offline availability",
)
def update_rider_duty_status(
    payload: schemas.DutyStatusUpdate,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Set `is_on_duty` to the boolean in the request body.

    `is_on_duty` is required by the schema (not Optional) — a PATCH
    without it is a client bug, and a 422 here catches it loudly rather
    than silently no-op'ing.
    """
    updates = {"is_on_duty": payload.is_on_duty}

    try:
        return crud.apply_user_updates(db, current_user, updates)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.put(
    "/rider/profile",
    response_model=schemas.RiderAccountOut,
    summary="Update basic rider profile info (name, district)",
)
def update_rider_profile(
    payload: schemas.RiderProfileUpdate,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Update the rider's name and district.

    `email` is intentionally NOT updatable here — same reasoning as the
    farmer profile endpoint. Changing the login identifier needs the OTP
    flow. `state` is fixed at Karnataka for the MVP and isn't exposed as
    an editable field.
    """
    updates = payload.model_dump(exclude_unset=True)

    if "full_name" in updates and updates["full_name"] is not None:
        updates["full_name"] = updates["full_name"].strip()
        if not updates["full_name"]:
            raise HTTPException(
                status_code=400,
                detail="full_name cannot be empty",
            )

    if "district" in updates and updates["district"] is not None:
        updates["district"] = updates["district"].strip() or None

    try:
        return crud.apply_user_updates(db, current_user, updates)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.put(
    "/rider/vehicle-details",
    response_model=schemas.RiderAccountOut,
    summary="Update driving license and vehicle specifications",
)
def update_rider_vehicle_details(
    payload: schemas.VehicleDetailsUpdate,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Update the rider's license number, vehicle type/number, and payload
    capacity.

    Normalization of `license_number` and `vehicle_number` (uppercase, no
    spaces) happens at the schema layer so the stored values are
    consistent regardless of how the rider typed them.
    """
    updates = payload.model_dump(exclude_unset=True)

    try:
        return crud.apply_user_updates(db, current_user, updates)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.put(
    "/rider/routes",
    response_model=schemas.RiderAccountOut,
    summary="Update preferred operating districts/routes",
)
def update_rider_routes(
    payload: schemas.RiderRoutesUpdate,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Update the rider's preferred operating routes.

    Stored as a single comma-separated string; the schema validator
    normalizes whitespace and strips empty entries. A rider who clears the
    field ends up with `None`, which the client renders as "any route".
    """
    updates = payload.model_dump(exclude_unset=True)

    try:
        return crud.apply_user_updates(db, current_user, updates)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.put(
    "/rider/payouts",
    response_model=schemas.RiderAccountOut,
    summary="Update bank account and UPI payout details",
)
def update_rider_payouts(
    payload: schemas.RiderPayoutUpdate,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Update the rider's payout destination.

    Values are stored as plain text — no checksum or penny-drop
    verification runs here. `ifsc_code`, `upi_id`, and `account_number`
    are normalized/validated at the schema layer (uppercase IFSC,
    lowercase UPI, digits-only account number with spaces stripped).
    """
    updates = payload.model_dump(exclude_unset=True)

    for field in ("bank_name", "account_number", "ifsc_code", "upi_id"):
        if field in updates and updates[field] is not None:
            updates[field] = updates[field].strip() or None

    try:
        return crud.apply_user_updates(db, current_user, updates)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Produce Requests
# ---------------------------------------------------------------------------

@app.post(
    "/produce-requests/",
    response_model=schemas.ProduceRequestResponse,
    status_code=201,
)
def create_produce_request(
    request: schemas.ProduceRequestCreate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Create a produce pickup request tied to the authenticated farmer,
    storing a PostGIS point and generating a 4-digit pickup OTP.
    """
    try:
        return crud.create_produce_request(db, request, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post(
    "/produce-requests/{request_id}/verify-otp",
    response_model=schemas.OtpVerifyResponse,
)
def verify_pickup_otp(
    request_id: UUID,
    body: schemas.OtpVerifyRequest,
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Verify the 4-digit PICKUP handoff OTP for a produce request and, on a
    match, flip the request's status to PICKED_UP.

    NOTE: this is a different flow from /auth/verify-otp (which handles
    the SIGNUP OTP).
    """
    try:
        result = crud.verify_pickup_otp(db, request_id, body.otp)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))
    if not result:
        raise HTTPException(status_code=404, detail="Produce request not found")

    return schemas.OtpVerifyResponse(
        success=True,
        message="OTP verified successfully!",
    )


@app.get(
    "/produce-requests/nearby",
    response_model=List[schemas.NearbyProduceRequestResponse],
)
def nearby_produce_requests(
    lat: float = Query(..., ge=-90, le=90, description="Rider's current latitude"),
    lng: float = Query(..., ge=-180, le=180, description="Rider's current longitude"),
    radius_km: float = Query(10, gt=0, le=200, description="Search radius in kilometers"),
    db: Session = Depends(get_db),
) -> List[schemas.NearbyProduceRequestResponse]:
    """Return PENDING produce requests within radius_km of the given point."""
    try:
        return crud.get_nearby_produce_requests(
            db, lat=lat, lng=lng, radius_km=radius_km
        )
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get(
    "/produce-requests/{request_id}",
    response_model=schemas.ProduceRequestResponse,
)
def get_produce_request(request_id: UUID, db: Session = Depends(get_db)):
    try:
        result = crud.get_produce_request_by_id(db, request_id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))
    if not result:
        raise HTTPException(status_code=404, detail="Produce request not found")
    return result


@app.get(
    "/produce-requests/farmer/me",
    response_model=List[schemas.FarmerProduceRequestResponse],
)
def get_my_produce_requests(
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """All of the authenticated farmer's produce requests, newest first."""
    try:
        return crud.get_produce_requests_for_farmer(db, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Trips
# ---------------------------------------------------------------------------

@app.post(
    "/trips/",
    response_model=schemas.ProduceRequestResponse,
    status_code=201,
)
def create_trip_request(
    request: schemas.ProduceRequestCreate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Create a produce pickup request for the authenticated farmer.

    NOTE: despite the URL, this creates a ProduceRequest row (status
    PENDING), not a Trip.
    """
    try:
        return crud.create_produce_request(db, request, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/trips/me", response_model=List[schemas.ProduceRequestResponse])
def get_my_trip_requests(
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """Flat list of the farmer's own produce requests, newest first."""
    try:
        return crud.get_farmer_produce_requests(db, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/trips/accept", response_model=schemas.TripResponse, status_code=201)
def accept_trip(
    request_id: UUID = Query(..., description="ID of the produce request being accepted"),
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    The authenticated rider accepts a PENDING produce request, creating a
    Trip and moving the request to 'ACCEPTED'.
    """
    try:
        return crud.accept_produce_request(db, request_id, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.patch("/trips/{trip_id}/status", response_model=schemas.TripResponse)
def update_trip_status(
    trip_id: UUID,
    body: schemas.TripStatusUpdate,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Transition a trip to PICKED_UP, DELIVERED, or CANCELLED. Only the
    rider assigned to the trip may update it.

    Transitioning to DELIVERED also:
      - marks the underlying produce request as COMPLETED, and
      - auto-creates a Settlement row for the trip.
    """
    trip = crud.get_trip_by_id(db, trip_id)
    if not trip:
        raise HTTPException(status_code=404, detail="Trip not found")
    if trip.rider_id != current_user.id:
        raise HTTPException(
            status_code=403,
            detail="You are not the rider assigned to this trip",
        )

    try:
        result = crud.update_trip_status(
            db, trip_id, body.status,
            distance_km=body.distance_km,
        )
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))
    if not result:
        raise HTTPException(status_code=404, detail="Trip not found")
    return result


@app.get("/trips/active", response_model=List[schemas.ActiveTripResponse])
def get_active_trips(
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    All of the authenticated rider's currently active trips (status
    ACCEPTED or PICKED_UP), newest first.
    """
    trips = crud.get_active_trips_for_rider(db, current_user.id)
    return [
        schemas.ActiveTripResponse(
            id=t.id,
            produce_request_id=t.produce_request_id,
            rider_id=t.rider_id,
            status=t.status,
            created_at=t.created_at,
            completed_at=t.completed_at,
            produce_request=crud._to_response(t.produce_request),
        )
        for t in trips
    ]


# ---------------------------------------------------------------------------
# Crate Scans
# ---------------------------------------------------------------------------

@app.post(
    "/crate-scans/",
    response_model=schemas.CrateScanResponse,
    status_code=201,
)
def create_crate_scan(
    scan: schemas.CrateScanCreate,
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Record a PICKUP or DELIVERY crate QR-code scan against a trip.
    """
    result = crud.create_crate_scan(db, scan, current_user.id)
    if not result:
        raise HTTPException(status_code=404, detail="Trip not found")
    return result


# ---------------------------------------------------------------------------
# Settlements
# ---------------------------------------------------------------------------

@app.post(
    "/settlements/",
    response_model=schemas.SettlementResponse,
    status_code=201,
)
def create_settlement(
    settlement_in: schemas.SettlementCreate,
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Manual / admin creation of a settlement for a DELIVERED trip.

    In the normal rider flow this endpoint is redundant — PATCH
    /trips/{trip_id}/status with {"status": "DELIVERED"} auto-creates the
    settlement in the same transaction.
    """
    try:
        result = crud.create_settlement(db, settlement_in)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))
    if not result:
        raise HTTPException(status_code=404, detail="Trip not found")
    return result


@app.get("/settlements/me", response_model=List[schemas.SettlementResponse])
def get_my_settlements(
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Role-based payout history for the authenticated user.
    """
    return crud.get_settlements_for_user(db, current_user.id, current_user.role)


# ---------------------------------------------------------------------------
# Admin analytics
# ---------------------------------------------------------------------------

@app.get("/admin/stats/", response_model=schemas.AdminStatsResponse)
def get_admin_stats(
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Platform-wide summary: user/farmer/rider counts, trip counts, and
    total payout volume.
    """
    return crud.get_admin_stats(db)


# ---------------------------------------------------------------------------
# Photo uploads
# ---------------------------------------------------------------------------

@app.post(
    "/uploads/delivery-photo",
    response_model=schemas.PhotoUploadResponse,
    status_code=201,
)
async def upload_delivery_photo(
    file: UploadFile = File(...),
    current_user: models.User = Depends(auth.get_current_user),
):
    """
    Upload a delivery proof-of-photo. Saves to local static storage and
    returns a URL the app can display or attach to a trip/settlement
    record.
    """
    if file.content_type not in ALLOWED_UPLOAD_CONTENT_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported file type: {file.content_type}. Allowed: "
            f"{', '.join(sorted(ALLOWED_UPLOAD_CONTENT_TYPES))}",
        )

    contents = await file.read()
    if len(contents) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=400, detail="File too large (max 10 MB)")
    if not contents:
        raise HTTPException(status_code=400, detail="Uploaded file is empty")

    extension = ALLOWED_UPLOAD_CONTENT_TYPES[file.content_type]
    filename = f"{uuid.uuid4()}{extension}"
    destination = UPLOAD_DIR / filename

    with open(destination, "wb") as f:
        f.write(contents)

    return schemas.PhotoUploadResponse(image_url=f"/static/uploads/{filename}")