"""
KisanRider FastAPI application.

Merge the endpoints below into your existing main.py (keep your current
/db-check endpoint as-is — it's reproduced here only for completeness).
"""

# --- Env / dotenv bootstrap (must run before anything reads os.environ) ---
from dotenv import load_dotenv
load_dotenv()

import asyncio
import math
import os
import random
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import List, Optional
from uuid import UUID

import httpx
from fastapi import Depends, FastAPI, File, HTTPException, Query, UploadFile
from fastapi.staticfiles import StaticFiles
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

import auth
import crud
import models
import schemas
from database import engine, get_db
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# Temporary startup diagnostic — remove once /mandi-rates/ is confirmed live.
print(f"[startup] DATA_GOV_API_KEY present: {bool(os.environ.get('DATA_GOV_API_KEY'))}")

app = FastAPI(title="KisanRider API")

# Allows Flutter Web on any local port to interact with FastAPI
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Create any tables defined in models.py that don't exist yet in Postgres
    (e.g. crate_scans) on startup.

    create_all() only issues CREATE TABLE IF NOT EXISTS for tables it
    doesn't find — it never touches a table that already exists, so it
    won't add/drop/alter a column on your existing users/produce_requests/
    trips tables no matter how their models.py definition has drifted from
    the live schema. That's exactly why the CrateScan model added a couple
    of rounds ago never actually created crate_scans in Postgres: nothing
    had called create_all() since that model was added, so every insert
    into it 500'd with "relation crate_scans does not exist" — the bare,
    non-JSON error body you're seeing is Postgres' error escaping past
    every try/except in crud.py/main.py, none of which catch a missing-
    table error specifically.

    For anything beyond "table doesn't exist yet" — an actual schema
    change to a column that already exists — create_all() does nothing;
    you'd need a real migration tool (Alembic) or a manual SQL script.
    """
    models.Base.metadata.create_all(bind=engine)
    yield


app = FastAPI(title="KisanRider API", lifespan=lifespan)

# Local static storage for delivery photos (see POST /uploads/delivery-photo
# below). Swap this whole block for real Supabase Storage in production —
# local disk storage doesn't survive a redeploy on most hosts and doesn't
# scale past one server instance.
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
# Health / diagnostics (existing)
# ---------------------------------------------------------------------------

@app.get("/db-check")
def db_check(db: Session = Depends(get_db)):
    try:
        result = db.execute(text("SELECT PostGIS_Version();")).fetchone()
        return {"database": "Connected", "postgis_version": result[0]}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database connection failed: {str(e)}")


# ---------------------------------------------------------------------------
# Mandi search (OpenStreetMap Overpass API — no API key required)
# ---------------------------------------------------------------------------

# District centers used as the search anchor. Overpass's bbox filter needs
# coordinates, not a place name, so we anchor on the district HQ. 30km
# half-width covers most districts; the four largest (Belagavi, Uttara
# Kannada, Kalaburagi, Ballari) are big enough that a mandi near their
# outer edge may fall outside — bump `radius_km` in search_mandis() or add
# secondary centers for those if that becomes a problem.
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

# Multiple Overpass mirrors. The public main instance is frequently
# overloaded and returns 504s; falling through to a second mirror usually
# succeeds. Order matters — cheapest/most-reliable first.
_OVERPASS_MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
_OVERPASS_USER_AGENT = "KisanRiderApp/1.0"

# Simple in-process cache: district (lowercased) -> (timestamp, mandis).
# Mandi locations don't change often; a 1-hour TTL keeps repeated dropdown
# selections from hammering Overpass. Multi-worker deploy: each worker gets
# its own cache — fine for MVP, swap for Redis if you scale out.
_MANDI_CACHE: dict[str, tuple[float, list[dict]]] = {}
_MANDI_CACHE_TTL = 3600  # seconds

# Terms that show up in OSM's Kannada/Hindi naming and can slip past even a
# word-boundary regex on some spellings. Belt-and-braces on top of the
# `\b(APMC|Mandi)\b` filter: drop anything whose name or address still
# contains one of these.
_MANDI_BLACKLIST = [
    "mandir", "mandira", "temple", "vidya", "kalamandir",
    "showroom", "school", "college", "church", "hospital",
]


def _bbox_around(lat: float, lng: float, radius_km: float) -> tuple[float, float, float, float]:
    """
    Return (south, west, north, east) for a square bounding box with the
    given half-width in kilometers, centered on (lat, lng).

    Overpass's bbox filter is dramatically cheaper than `around:` — the
    latter has to compute great-circle distance for every candidate element
    on the planet, while the former is a spatial-index range scan.
    """
    lat_delta = radius_km / 111.0
    lng_delta = radius_km / (111.0 * math.cos(math.radians(lat)))
    return (lat - lat_delta, lng - lng_delta, lat + lat_delta, lng + lng_delta)


@app.get("/mandis/search")
async def search_mandis(
    district: str = Query(..., min_length=1, max_length=80,
                          description="District name, e.g. 'Kolar'"),
):
    """
    Find APMC mandis / market yards in a district via OpenStreetMap's
    Overpass API (free, no API key).

    Why Overpass, not Nominatim: Nominatim is a *forward geocoder*
    (text -> one best-matching place) and does not index "APMC yard" as a
    category — free-form queries like "APMC market yard Kolar Karnataka"
    legitimately return zero hits even when the yard exists in OSM. Overpass
    is a *POI query engine*: it returns every element matching an OSM tag
    inside a geographic region, which is exactly what "list mandis in this
    district" needs.

    Noise filtering (two layers, both required):
      1. The Overpass `name` regex uses word boundaries — `\\b(APMC|Mandi)\\b`
         — so "Mandikallu" (village) and "Ranga Mandira" (theatre) don't
         substring-match "Mandi".
      2. Any remaining result whose name or address contains a term from
         _MANDI_BLACKLIST (temple/mandir/school/showroom/hospital...) is
         dropped before returning.

    Response shape is unchanged, so the Flutter client needs no update:
        {
          "district": "Kolar",
          "mandis": [ { "name", "address", "lat", "lng" }, ... ]
        }
    """
    district_clean = district.strip()
    center = _DISTRICT_CENTERS.get(district_clean)
    if center is None:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown district: {district_clean}",
        )

    # Cache hit?
    cache_key = district_clean.lower()
    now = time.time()
    cached = _MANDI_CACHE.get(cache_key)
    if cached and (now - cached[0]) < _MANDI_CACHE_TTL:
        return {"district": district_clean, "mandis": cached[1]}

    lat, lng = center
    south, west, north, east = _bbox_around(lat, lng, radius_km=30.0)
    bbox = f"{south},{west},{north},{east}"

    # `nwr` = node+way+relation shorthand. Word-boundary regex so "Mandi"
    # only matches as a whole word. `out center tags;` puts a usable
    # centroid on ways and relations.
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

        # Overpass returns lat/lon directly on nodes; ways and relations
        # have their centroid under `center` because of `out center`.
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

        # Second-layer noise filter. Covers both the name and address, so a
        # stray "Sri Vidya Mandir APMC Road" still gets dropped.
        haystack = f"{name} {address}".lower()
        if any(term in haystack for term in _MANDI_BLACKLIST):
            continue

        mandis.append({
            "name": name,
            "address": address,
            "lat": float(el_lat),
            "lng": float(el_lng),
        })

    # Dedupe on (name, rounded coords) — same yard often appears as a node
    # plus the way/relation enclosing it.
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

# Data.gov.in resource id for "Variety-wise Daily Market Prices Data of
# Commodity" (the Agmarknet feed). The key is free — register at
# https://data.gov.in and paste it into the DATA_GOV_API_KEY env var.
# When the key is missing or the call fails, we fall back to local mock
# data so the app never shows a broken screen.
_DATA_GOV_BASE_URL = (
    "https://api.data.gov.in/resource/9ef84268-d588-465a-a308-a864a43d0070"
)

# Districts the app offers rates for. Exposed in the response so the
# frontend dropdown can render itself from server truth.
_MANDI_RATE_DISTRICTS = [
    "Kolar",
    "Bengaluru Urban",
    "Mandya",
    "Belagavi",
    "Davanagere",
]

# Local fallback rates per district. Prices are typical Karnataka APMC
# modal prices in ₹ per quintal (1 qtl = 100 kg). Used only when the live
# call can't be made — values are reasonable, not authoritative.
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
    """
    Return local mock rates for `district`, or the Kolar set as a generic
    fallback for districts we don't have curated data for. Keeps the
    response shape consistent no matter what.
    """
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
    district: Optional[str] = Query(
        None, max_length=80,
        description="District name, e.g. 'Kolar'. Defaults to 'Kolar'.",
    ),
):
    """
    Today's modal mandi prices for a Karnataka district.

    Tries Data.gov.in's Agmarknet resource first when DATA_GOV_API_KEY is
    set; falls back to a small local mock dataset on any failure (missing
    key, timeout, HTTP error, unexpected response shape) so the client
    never has to handle an empty screen.

    Response shape:
        {
          "status": "success",
          "source": "live" | "mock",
          "selected_district": "Kolar",
          "available_districts": ["Kolar", "Bengaluru Urban", ...],
          "rates": [
            {"crop": "Tomato", "modal_price": "₹2200 / Qtl", "mandi": "Kolar APMC"},
            ...
          ]
        }

    `status` is always "success" even on the fallback path — the point of
    the endpoint is that it never returns a broken screen. `source` tells
    the client (and you, while debugging) which path actually executed.
    """
    selected_district = (district or "Kolar").strip()

    api_key = os.environ.get("DATA_GOV_API_KEY")
    rates: list[dict] | None = None

    if api_key:
        try:
            async with httpx.AsyncClient(timeout=25.0) as client:
                # --- Attempt 1: with the filters we originally wrote ---
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
                print(f"[mandi-rates] filtered total={payload.get('total')} "
                      f"count={payload.get('count')} "
                      f"records={len(payload.get('records', []))}")

                records = payload.get("records") if isinstance(payload, dict) else None

                # --- Attempt 2: no filters at all, filter client-side ---
                # Data.gov.in's filter parameter names vary by resource; if
                # the filtered call returns zero rows, this fallback hits
                # the bare resource and matches state/district ourselves.
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

                    # Filter locally by state + district, tolerating both
                    # lowercase and Capitalized field names.
                    def _field(rec, *names):
                        for n in names:
                            v = rec.get(n)
                            if v:
                                return str(v).strip().lower()
                        return ""

                    records = [
                        r for r in all_records
                        if _field(r, "state", "State") == "karnataka"
                        and _field(r, "district", "District") == selected_district.lower()
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
# Dev-only auth (local testing in Swagger UI)
# ---------------------------------------------------------------------------

@app.post("/auth/dev-token")
def issue_dev_token(
    user_id: UUID = Query(..., description="Existing user to mint a test token for"),
    db: Session = Depends(get_db),
):
    """
    Mint a short-lived access token for an existing user, for exercising
    protected endpoints from Swagger UI without going through Supabase Auth.

    404s in production (ENVIRONMENT=production) rather than merely
    rejecting the token mint — DEV_MODE is checked before touching the DB
    at all, so this route has zero attack surface once deployed for real:
    it behaves as if it doesn't exist. It's a complete auth bypass by
    design (any real user_id in, a valid token for that user out, no
    password), which is exactly why it can't be reachable outside
    development.
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
    """Register a new farmer or rider."""
    if crud.get_user_by_phone(db, user.phone):
        raise HTTPException(status_code=400, detail="Phone number already registered")

    try:
        return crud.create_user(db, user)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Produce Requests
# ---------------------------------------------------------------------------

@app.post("/produce-requests/", response_model=schemas.ProduceRequestResponse, status_code=201)
def create_produce_request(
    request: schemas.ProduceRequestCreate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Create a produce pickup request tied to the authenticated farmer,
    storing a PostGIS point and generating a 4-digit pickup OTP.

    NOTE: the OTP is generated inside crud.create_produce_request — that's
    where the DB insert happens, and threading a new `pickup_otp` parameter
    through this endpoint would only move the same logic. `random` is
    imported above for parity with the spec but is unused here.
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
    Verify the 4-digit pickup OTP for a produce request and, on a match,
    flip the request's status to PICKED_UP.

    Gated only by auth.get_current_user — both the farmer and the assigned
    rider are legitimate callers in different workflows (the farmer
    confirms the handoff, or the rider enters the code the farmer read out).
    If you want to narrow this to one role, swap `get_current_user` for
    `require_role("RIDER")` (or "FARMER").

    404 if the request doesn't exist. 400 for every domain failure — wrong
    OTP, request isn't ACCEPTED yet, or request is already in a terminal
    state (COMPLETED/CANCELLED).
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


@app.get("/produce-requests/nearby", response_model=List[schemas.NearbyProduceRequestResponse])
def nearby_produce_requests(
    lat: float = Query(..., ge=-90, le=90, description="Rider's current latitude"),
    lng: float = Query(..., ge=-180, le=180, description="Rider's current longitude"),
    radius_km: float = Query(10, gt=0, le=200, description="Search radius in kilometers"),
    db: Session = Depends(get_db),
) -> List[schemas.NearbyProduceRequestResponse]:
    """Return PENDING produce requests within radius_km of the given point, nearest first."""
    try:
        return crud.get_nearby_produce_requests(db, lat=lat, lng=lng, radius_km=radius_km)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/produce-requests/{request_id}", response_model=schemas.ProduceRequestResponse)
def get_produce_request(request_id: UUID, db: Session = Depends(get_db)):
    try:
        result = crud.get_produce_request_by_id(db, request_id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))
    if not result:
        raise HTTPException(status_code=404, detail="Produce request not found")
    return result


@app.get("/produce-requests/farmer/me", response_model=List[schemas.FarmerProduceRequestResponse])
def get_my_produce_requests(
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    All of the authenticated farmer's produce requests, newest first, each
    including the assigned rider and trip status once a rider has accepted
    it (null while still PENDING), and the pickup OTP the farmer reads to
    the rider at handoff.
    """
    try:
        return crud.get_produce_requests_for_farmer(db, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Trips
# ---------------------------------------------------------------------------

# MVP alias — creates a ProduceRequest, not a Trip. Semantically duplicates
# POST /produce-requests/; kept because it was requested. A Trip row only
# exists once a rider accepts via /trips/accept.
@app.post("/trips/", response_model=schemas.ProduceRequestResponse, status_code=201)
def create_trip_request(
    request: schemas.ProduceRequestCreate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Create a produce pickup request for the authenticated farmer.

    NOTE: despite the URL, this creates a ProduceRequest row (status
    PENDING), not a Trip. A Trip only comes into existence when a rider
    accepts. Payload = crop_type, crate_count, weight_kg, latitude,
    longitude, dropoff_location.
    """
    try:
        return crud.create_produce_request(db, request, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


# Flat MVP list of the farmer's own produce requests.
@app.get("/trips/me", response_model=List[schemas.ProduceRequestResponse])
def get_my_trip_requests(
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    All produce requests belonging to the authenticated farmer, newest
    first. Flat response (no nested trip/rider) — the MVP view. For the
    richer feed that includes rider + trip status, use
    GET /produce-requests/farmer/me.
    """
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
    Trip and moving the request to 'ACCEPTED'. Fails with 400 if the
    request doesn't exist or is no longer PENDING (already accepted/
    cancelled/etc).
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
    Transition a trip to PICKED_UP, DELIVERED, or CANCELLED. Only the rider
    assigned to the trip may update it — any other authenticated rider gets
    403, which is why we fetch the trip first rather than letting
    crud.update_trip_status run unconditionally.

    Transitioning to DELIVERED also marks the underlying produce request as
    COMPLETED. Trips already in a terminal state (DELIVERED/CANCELLED)
    reject further updates with a 400.
    """
    trip = crud.get_trip_by_id(db, trip_id)
    if not trip:
        raise HTTPException(status_code=404, detail="Trip not found")
    if trip.rider_id != current_user.id:
        raise HTTPException(status_code=403, detail="You are not the rider assigned to this trip")

    try:
        result = crud.update_trip_status(db, trip_id, body.status)
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
    All of the authenticated rider's currently active trips (status ACCEPTED
    or PICKED_UP), newest first. Returns an empty list (200) when the rider
    has no active trips — no more 404 on the happy empty case.
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

@app.post("/crate-scans/", response_model=schemas.CrateScanResponse, status_code=201)
def create_crate_scan(
    scan: schemas.CrateScanCreate,
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Record a PICKUP or DELIVERY crate QR-code scan against a trip, logged
    under whichever authenticated user (farmer or rider) performed it.
    404s if the trip doesn't exist.
    """
    result = crud.create_crate_scan(db, scan, current_user.id)
    if not result:
        raise HTTPException(status_code=404, detail="Trip not found")
    return result


# ---------------------------------------------------------------------------
# Settlements
# ---------------------------------------------------------------------------

@app.post("/settlements/", response_model=schemas.SettlementResponse, status_code=201)
def create_settlement(
    settlement_in: schemas.SettlementCreate,
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Create the payout settlement for a DELIVERED trip: base fare + distance
    fare + weight surcharge. 404 if the trip doesn't exist; 400 if it isn't
    DELIVERED yet or already has a settlement.
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
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """Payout history for the authenticated rider, newest first."""
    return crud.get_rider_settlements(db, current_user.id)


# ---------------------------------------------------------------------------
# Admin analytics
# ---------------------------------------------------------------------------

@app.get("/admin/stats/", response_model=schemas.AdminStatsResponse)
def get_admin_stats(
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Platform-wide summary: user/farmer/rider counts, trip counts, and total
    payout volume.

    NOTE: gated only by auth.get_current_user, exactly as specified — there
    is no ADMIN role in this codebase yet (only FARMER/RIDER), so right now
    *any* logged-in farmer or rider can see platform-wide numbers, not just
    staff. If that's not intended, this needs a real admin role added to
    users.role and require_role("ADMIN") here instead.
    """
    return crud.get_admin_stats(db)


# ---------------------------------------------------------------------------
# Photo uploads
# ---------------------------------------------------------------------------

@app.post("/uploads/delivery-photo", response_model=schemas.PhotoUploadResponse, status_code=201)
async def upload_delivery_photo(
    file: UploadFile = File(...),
    current_user: models.User = Depends(auth.get_current_user),
):
    """
    Upload a delivery proof-of-photo. Saves to local static storage (see
    the UPLOAD_DIR/StaticFiles mount near the top of this file) and returns
    a URL the app can display or attach to a trip/settlement record.

    Auth wasn't specified for this endpoint in the task, but every other
    write endpoint in this file requires a caller — leaving file upload as
    the one open door would let anyone fill your disk with arbitrary
    uploads, so Depends(auth.get_current_user) is applied here too.

    The uploaded filename is never trusted for the saved path (a client
    could send `../../etc/passwd` as a filename) — the stored name is
    always a fresh UUID plus an extension this server chose, not anything
    from the request.
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