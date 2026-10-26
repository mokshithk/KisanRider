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
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Optional
from uuid import UUID

import httpx
from fastapi import Depends, FastAPI, File, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy import and_, or_, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, joinedload

import auth
import config
import crud
import models
import pools.models  # noqa: F401  -- registers Pool/PoolMember/PoolStop on Base.metadata
from pools.router import router as pools_router  # PHASE 2 -- pools endpoints
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
    (e.g. crate_scans, saved_addresses) on startup.

    create_all() only issues CREATE TABLE IF NOT EXISTS for tables it
    doesn't find — it never alters an existing table. New columns on the
    `users`, `produce_requests`, and `trips` tables must be applied to an
    existing database with a manual ALTER TABLE. See the migration
    snippets in the module docstrings of models.py, or run:

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
            NOT NULL DEFAULT 'en',
          ADD COLUMN IF NOT EXISTS is_on_duty          BOOLEAN
            NOT NULL DEFAULT FALSE,
          ADD COLUMN IF NOT EXISTS license_number      VARCHAR(30),
          ADD COLUMN IF NOT EXISTS vehicle_type        VARCHAR(80),
          ADD COLUMN IF NOT EXISTS vehicle_number      VARCHAR(20),
          ADD COLUMN IF NOT EXISTS payload_capacity_kg DOUBLE PRECISION,
          ADD COLUMN IF NOT EXISTS operating_routes    VARCHAR(255),
          ADD COLUMN IF NOT EXISTS phone_number        VARCHAR(15);

        CREATE INDEX IF NOT EXISTS ix_users_phone_number
          ON users (phone_number);

        ALTER TABLE produce_requests
          ADD COLUMN IF NOT EXISTS pickup_address        VARCHAR(500),
          ADD COLUMN IF NOT EXISTS pickup_landmark       VARCHAR(255),
          ADD COLUMN IF NOT EXISTS dropoff_district      VARCHAR(80),
          ADD COLUMN IF NOT EXISTS dropoff_mandi_id      VARCHAR(160),
          ADD COLUMN IF NOT EXISTS dropoff_mandi_name    VARCHAR(200),
          ADD COLUMN IF NOT EXISTS dropoff_stall_number  VARCHAR(80);

        -- The Book Transport refactor moved the sole quantity metric to
        -- `weight_kg`. `crate_count` is no longer written by the ORM;
        -- make it nullable so any legacy INSERT that still sends it
        -- doesn't fail on the NOT NULL constraint.
        ALTER TABLE produce_requests
          ALTER COLUMN crate_count DROP NOT NULL;

        ALTER TABLE trips
          ADD COLUMN IF NOT EXISTS pickup_address   VARCHAR(500),
          ADD COLUMN IF NOT EXISTS pickup_landmark  VARCHAR(255),
          ADD COLUMN IF NOT EXISTS pickup_latitude  DOUBLE PRECISION,
          ADD COLUMN IF NOT EXISTS pickup_longitude DOUBLE PRECISION;
    """
    models.Base.metadata.create_all(bind=engine)
    
    # Auto-migration for the new cancellation_reason column
    with engine.connect() as conn:
        try:
            conn.execute(text(
                "ALTER TABLE produce_requests "
                "ADD COLUMN IF NOT EXISTS cancellation_reason VARCHAR(500);"
            ))
            conn.commit()
            print("[startup] Checked/added cancellation_reason column.")
        except Exception as e:
            print(f"[startup] Migration note: {e}")

        # PHASE 3 — link trips to pools (D1 = Option A, N Trips per Pool).
        # Auto-migration: safe on fresh DBs (column already exists from
        # create_all) and on existing DBs (adds the column in place).
        try:
            conn.execute(text(
                "ALTER TABLE trips "
                "ADD COLUMN IF NOT EXISTS pool_id UUID "
                "REFERENCES pools(id) ON DELETE SET NULL;"
            ))
            conn.commit()
            print("[startup] Checked/added trips.pool_id column.")
        except Exception as e:
            print(f"[startup] Migration note (trips.pool_id): {e}")
            
    yield


app = FastAPI(title="KisanRider API", lifespan=lifespan)

# PHASE 2 -- mount the farmer-pooling router
app.include_router(pools_router)

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


async def _overpass_search_local_markets(district_clean: str) -> list[dict]:
    """
    Shared helper: run the Overpass query for a district and return a
    deduplicated list of `{name, address, lat, lng}` dicts.

    This is the *local market* data source — it catches unregistered
    town markets, fish markets, and regional yards (e.g. "Manjeshwar
    Fish Market") that a district-level APMC register wouldn't list.

    Both `GET /mandis/search` (legacy) and `GET /mandi/markets` (the
    dual-source endpoint) reuse this helper so the caching and filtering
    behavior stay consistent. Results are cached for one hour per
    district; the cache is shared between the two endpoints.

    Raises `HTTPException(502)` if every Overpass mirror fails — the
    caller decides whether to surface that to the client or fall back to
    an empty list (the `/mandi/markets` endpoint does the latter so the
    APMC results still come through).
    """
    center = _DISTRICT_CENTERS.get(district_clean)
    if center is None:
        return []

    cache_key = district_clean.lower()
    now = time.time()
    cached = _MANDI_CACHE.get(cache_key)
    if cached and (now - cached[0]) < _MANDI_CACHE_TTL:
        return cached[1]

    lat, lng = center
    south, west, north, east = _bbox_around(lat, lng, radius_km=30.0)
    bbox = f"{south},{west},{north},{east}"

    overpass_query = f"""
    [out:json][timeout:60];
    (
      nwr["amenity"="marketplace"]({bbox});
      nwr["name"~"\\\\b(APMC|Mandi)\\\\b",i]({bbox});
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
    return unique


@app.get("/mandis/search")
async def search_mandis(
    district: str = Query(..., min_length=1, max_length=80),
):
    """
    Find APMC mandis / market yards in a district via OpenStreetMap's
    Overpass API (free, no API key).

    LEGACY endpoint — returns only the Overpass-discovered local
    markets. For the dual-source view that merges official APMC yards
    from the Agmarknet register with these local markets, use
    `GET /mandi/markets`.
    """
    district_clean = district.strip()
    if district_clean not in _DISTRICT_CENTERS:
        raise HTTPException(status_code=400, detail=f"Unknown district: {district_clean}")

    mandis = await _overpass_search_local_markets(district_clean)
    return {"district": district_clean, "mandis": mandis}


# ---------------------------------------------------------------------------
# Mandi rates (Data.gov.in Agmarknet — optional API key, mock fallback)
# ---------------------------------------------------------------------------

_DATA_GOV_BASE_URL = (
    "https://api.data.gov.in/resource/9ef84268-d588-465a-a308-a864a43d0070"
)

# All 31 Karnataka districts. Used as the canonical list in the response's
# `available_districts` field, so the frontend's dropdown is always in sync
# with what the backend actually serves. Must stay aligned with
# `_MOCK_MANDI_RATES` below — every district here should have an entry there.
_MANDI_RATE_DISTRICTS: list[str] = [
    "Bagalkot",
    "Ballari",
    "Belagavi",
    "Bengaluru Rural",
    "Bengaluru Urban",
    "Bidar",
    "Chamarajanagar",
    "Chikkaballapura",
    "Chikkamagaluru",
    "Chitradurga",
    "Dakshina Kannada",
    "Davanagere",
    "Dharwad",
    "Gadag",
    "Hassan",
    "Haveri",
    "Kalaburagi",
    "Kodagu",
    "Kolar",
    "Koppal",
    "Mandya",
    "Mysuru",
    "Raichur",
    "Ramanagara",
    "Shivamogga",
    "Tumakuru",
    "Udupi",
    "Uttara Kannada",
    "Vijayapura",
    "Yadgir",
    "Vijayanagara",
]

# Mock rates for every district the dropdown offers. Each entry is a real
# crop the district is known for, priced plausibly for a 2024-25 season.
# Values are bare integers (₹ per quintal) — formatted into
# "₹X / Qtl" at the API boundary so the wire format stays consistent
# regardless of whether the row originated here or from Data.gov.in.
_MOCK_MANDI_RATES: dict[str, list[dict]] = {
    "Bagalkot": [
        {"crop": "Sugarcane", "modal_price": 320, "mandi": "Bagalkot APMC"},
        {"crop": "Onion",     "modal_price": 2600, "mandi": "Bagalkot APMC"},
        {"crop": "Jowar",     "modal_price": 3100, "mandi": "Jamkhandi APMC"},
    ],
    "Ballari": [
        {"crop": "Onion",     "modal_price": 2400, "mandi": "Ballari APMC"},
        {"crop": "Cotton",    "modal_price": 6800, "mandi": "Hospet APMC"},
        {"crop": "Maize",     "modal_price": 1950, "mandi": "Ballari APMC"},
    ],
    "Belagavi": [
        {"crop": "Sugarcane", "modal_price": 310, "mandi": "Belagavi APMC"},
        {"crop": "Maize",     "modal_price": 1950, "mandi": "Belagavi APMC"},
        {"crop": "Soybean",   "modal_price": 4300, "mandi": "Bailhongal APMC"},
        {"crop": "Onion",     "modal_price": 2700, "mandi": "Bailhongal APMC"},
    ],
    "Bengaluru Rural": [
        {"crop": "Tomato",    "modal_price": 2050, "mandi": "Doddaballapura APMC"},
        {"crop": "Beans",     "modal_price": 3500, "mandi": "Devanahalli APMC"},
        {"crop": "Ragi",      "modal_price": 3300, "mandi": "Nelamangala APMC"},
    ],
    "Bengaluru Urban": [
        {"crop": "Tomato",    "modal_price": 2100, "mandi": "Yeshwanthpur APMC"},
        {"crop": "Carrot",    "modal_price": 3000, "mandi": "Yeshwanthpur APMC"},
        {"crop": "Beans",     "modal_price": 3600, "mandi": "Binny Mill APMC"},
        {"crop": "Onion",     "modal_price": 2600, "mandi": "Binny Mill APMC"},
    ],
    "Bidar": [
        {"crop": "Tur dal",   "modal_price": 7200, "mandi": "Bidar APMC"},
        {"crop": "Soybean",   "modal_price": 4400, "mandi": "Bidar APMC"},
        {"crop": "Sugarcane", "modal_price": 305,  "mandi": "Bhalki APMC"},
    ],
    "Chamarajanagar": [
        {"crop": "Ragi",      "modal_price": 3250, "mandi": "Chamarajanagar APMC"},
        {"crop": "Paddy",     "modal_price": 2250, "mandi": "Chamarajanagar APMC"},
        {"crop": "Banana",    "modal_price": 1800, "mandi": "Kollegal APMC"},
    ],
    "Chikkaballapura": [
        {"crop": "Tomato",    "modal_price": 2150, "mandi": "Chikkaballapura APMC"},
        {"crop": "Onion",     "modal_price": 2650, "mandi": "Chickballapur APMC"},
        {"crop": "Ragi",      "modal_price": 3350, "mandi": "Gauribidanur APMC"},
    ],
    "Chikkamagaluru": [
        {"crop": "Coffee",    "modal_price": 12500,  "mandi": "Chikkamagaluru APMC"},
        {"crop": "Pepper",    "modal_price": 48000,  "mandi": "Chikkamagaluru APMC"},
        {"crop": "Arecanut",  "modal_price": 38000,  "mandi": "Kadur APMC"},
        {"crop": "Cardamom",  "modal_price": 180000, "mandi": "Chikkamagaluru APMC"},
    ],
    "Chitradurga": [
        {"crop": "Onion",     "modal_price": 2500, "mandi": "Chitradurga APMC"},
        {"crop": "Maize",     "modal_price": 2000, "mandi": "Chitradurga APMC"},
        {"crop": "Ragi",      "modal_price": 3200, "mandi": "Hiriyur APMC"},
    ],
    "Dakshina Kannada": [
        {"crop": "Arecanut",  "modal_price": 41000, "mandi": "Puttur APMC"},
        {"crop": "Cashew",    "modal_price": 12500, "mandi": "Mangaluru APMC"},
        {"crop": "Coconut",   "modal_price": 2100,  "mandi": "Puttur APMC"},
        {"crop": "Cocoa",     "modal_price": 32000, "mandi": "Mangaluru APMC"},
    ],
    "Davanagere": [
        {"crop": "Maize",     "modal_price": 2000, "mandi": "Davanagere APMC"},
        {"crop": "Paddy",     "modal_price": 2300, "mandi": "Davanagere APMC"},
        {"crop": "Cotton",    "modal_price": 6800, "mandi": "Harihar APMC"},
        {"crop": "Sunflower", "modal_price": 6000, "mandi": "Harihar APMC"},
    ],
    "Dharwad": [
        {"crop": "Onion",     "modal_price": 2600, "mandi": "Hubballi APMC"},
        {"crop": "Maize",     "modal_price": 1980, "mandi": "Dharwad APMC"},
        {"crop": "Cotton",    "modal_price": 6900, "mandi": "Dharwad APMC"},
    ],
    "Gadag": [
        {"crop": "Onion",     "modal_price": 2550, "mandi": "Gadag APMC"},
        {"crop": "Jowar",     "modal_price": 3150, "mandi": "Gadag APMC"},
        {"crop": "Maize",     "modal_price": 1960, "mandi": "Ron APMC"},
    ],
    "Hassan": [
        {"crop": "Coffee",    "modal_price": 12200, "mandi": "Hassan APMC"},
        {"crop": "Paddy",     "modal_price": 2280,  "mandi": "Hassan APMC"},
        {"crop": "Arecanut",  "modal_price": 39000, "mandi": "Sakleshpur APMC"},
        {"crop": "Coconut",   "modal_price": 2050,  "mandi": "Arakalagud APMC"},
    ],
    "Haveri": [
        {"crop": "Maize",     "modal_price": 1990, "mandi": "Haveri APMC"},
        {"crop": "Onion",     "modal_price": 2620, "mandi": "Haveri APMC"},
        {"crop": "Cotton",    "modal_price": 6750, "mandi": "Ranebennur APMC"},
    ],
    "Kalaburagi": [
        {"crop": "Tur dal",   "modal_price": 7400, "mandi": "Kalaburagi APMC"},
        {"crop": "Jowar",     "modal_price": 3200, "mandi": "Kalaburagi APMC"},
        {"crop": "Sunflower", "modal_price": 6100, "mandi": "Afzalpur APMC"},
    ],
    "Kodagu": [
        {"crop": "Coffee",    "modal_price": 12800,  "mandi": "Madikeri APMC"},
        {"crop": "Pepper",    "modal_price": 49000,  "mandi": "Madikeri APMC"},
        {"crop": "Cardamom",  "modal_price": 185000, "mandi": "Kushalnagar APMC"},
        {"crop": "Arecanut",  "modal_price": 40000,  "mandi": "Virajpet APMC"},
    ],
    "Kolar": [
        {"crop": "Tomato",  "modal_price": 2200, "mandi": "Kolar APMC"},
        {"crop": "Onion",   "modal_price": 2800, "mandi": "Kolar APMC"},
        {"crop": "Potato",  "modal_price": 1900, "mandi": "Bangarpet APMC"},
        {"crop": "Beans",   "modal_price": 3400, "mandi": "Chintamani APMC"},
    ],
    "Koppal": [
        {"crop": "Paddy",     "modal_price": 2320, "mandi": "Koppal APMC"},
        {"crop": "Maize",     "modal_price": 2020, "mandi": "Koppal APMC"},
        {"crop": "Onion",     "modal_price": 2580, "mandi": "Gangavathi APMC"},
    ],
    "Mandya": [
        {"crop": "Sugarcane", "modal_price": 320,  "mandi": "Mandya APMC"},
        {"crop": "Ragi",      "modal_price": 3300, "mandi": "Mandya APMC"},
        {"crop": "Paddy",     "modal_price": 2200, "mandi": "Maddur APMC"},
        {"crop": "Coconut",   "modal_price": 1800, "mandi": "Maddur APMC"},
    ],
    "Mysuru": [
        {"crop": "Ragi",      "modal_price": 3280, "mandi": "Mysuru APMC"},
        {"crop": "Paddy",     "modal_price": 2270, "mandi": "Mysuru APMC"},
        {"crop": "Banana",    "modal_price": 1750, "mandi": "Nanjangud APMC"},
        {"crop": "Sugarcane", "modal_price": 315,  "mandi": "Mysuru APMC"},
    ],
    "Raichur": [
        {"crop": "Paddy",     "modal_price": 2340, "mandi": "Raichur APMC"},
        {"crop": "Cotton",    "modal_price": 7000, "mandi": "Raichur APMC"},
        {"crop": "Tur dal",   "modal_price": 7300, "mandi": "Sindhanur APMC"},
    ],
    "Ramanagara": [
        {"crop": "Ragi",      "modal_price": 3320, "mandi": "Ramanagara APMC"},
        {"crop": "Coconut",   "modal_price": 1950, "mandi": "Ramanagara APMC"},
        {"crop": "Tomato",    "modal_price": 2080, "mandi": "Channapatna APMC"},
    ],
    "Shivamogga": [
        {"crop": "Arecanut",  "modal_price": 38500, "mandi": "Shivamogga APMC"},
        {"crop": "Paddy",     "modal_price": 2260,  "mandi": "Shivamogga APMC"},
        {"crop": "Coconut",   "modal_price": 2050,  "mandi": "Bhadravathi APMC"},
        {"crop": "Ginger",    "modal_price": 8500,  "mandi": "Sagar APMC"},
    ],
    "Tumakuru": [
        {"crop": "Coconut",   "modal_price": 2000,  "mandi": "Tumakuru APMC"},
        {"crop": "Ragi",      "modal_price": 3260,  "mandi": "Tumakuru APMC"},
        {"crop": "Paddy",     "modal_price": 2240,  "mandi": "Tiptur APMC"},
        {"crop": "Arecanut",  "modal_price": 37500, "mandi": "Tiptur APMC"},
    ],
    "Udupi": [
        {"crop": "Paddy",     "modal_price": 2300,  "mandi": "Udupi APMC"},
        {"crop": "Coconut",   "modal_price": 2100,  "mandi": "Udupi APMC"},
        {"crop": "Arecanut",  "modal_price": 40000, "mandi": "Kundapura APMC"},
        {"crop": "Cashew",    "modal_price": 12500, "mandi": "Karkala APMC"},
    ],
    "Uttara Kannada": [
        {"crop": "Arecanut",  "modal_price": 40500, "mandi": "Sirsi APMC"},
        {"crop": "Pepper",    "modal_price": 48500, "mandi": "Sirsi APMC"},
        {"crop": "Coconut",   "modal_price": 2050,  "mandi": "Kumta APMC"},
        {"crop": "Cashew",    "modal_price": 12300, "mandi": "Kumta APMC"},
    ],
    "Vijayapura": [
        {"crop": "Sugarcane", "modal_price": 315,  "mandi": "Vijayapura APMC"},
        {"crop": "Onion",     "modal_price": 2700, "mandi": "Vijayapura APMC"},
        {"crop": "Grapes",    "modal_price": 8500, "mandi": "Vijayapura APMC"},
        {"crop": "Jowar",     "modal_price": 3180, "mandi": "Indi APMC"},
    ],
    "Yadgir": [
        {"crop": "Tur dal",   "modal_price": 7250, "mandi": "Yadgir APMC"},
        {"crop": "Paddy",     "modal_price": 2310, "mandi": "Shahapur APMC"},
        {"crop": "Cotton",    "modal_price": 6850, "mandi": "Yadgir APMC"},
    ],
    "Vijayanagara": [
        {"crop": "Paddy",     "modal_price": 2280, "mandi": "Hosapete APMC"},
        {"crop": "Jowar",     "modal_price": 3120, "mandi": "Hosapete APMC"},
        {"crop": "Onion",     "modal_price": 2550, "mandi": "Hagaribommanahalli APMC"},
    ],
}

# Sanity: the dropdown list and the mock dataset must cover exactly the same
# districts. If you add a district to one, add it to the other.
assert set(_MANDI_RATE_DISTRICTS) == set(_MOCK_MANDI_RATES.keys()), (
    "District lists diverged — _MANDI_RATE_DISTRICTS and "
    "_MOCK_MANDI_RATES must cover the same districts"
)


def _mock_rates_for(district: str) -> list[dict]:
    """
    Return mock rates for one district, each tagged with its `district`.

    Returns an EMPTY list for a district we don't have data for. The old
    behavior silently returned Kolar's data under the requested district's
    label, which is misleading for a farmer who selected, say,
    Dakshina Kannada. An honest empty list is the right contract — the
    frontend renders a "no rates" message instead.
    """
    chosen = _MOCK_MANDI_RATES.get(district)
    if chosen is None:
        return []
    return [
        {
            "district": district,
            "crop": r["crop"],
            "modal_price": f"₹{r['modal_price']} / Qtl",
            "mandi": r["mandi"],
        }
        for r in chosen
    ]


def _normalize_district_filter(raw: str) -> Optional[str]:
    """
    Parse the incoming `district` query param.

    Returns None when the caller wants "all districts" — either because
    they omitted the param or because they sent a sentinel value the
    Flutter client uses ("All Karnataka"). Everything else is passed
    through trimmed.
    """
    if not raw or not raw.strip():
        return None
    cleaned = raw.strip()
    if cleaned.lower() in ("all", "all karnataka", "karnataka"):
        return None
    return cleaned


def _parse_live_records(
    records: list[dict],
    filter_district: Optional[str] = None,
) -> list[dict]:
    """
    Parse a list of Data.gov.in Agmarknet records into the same shape
    `_mock_rates_for` produces.

    When `filter_district` is set, only rows matching that district survive.
    When it's None, every Karnataka row is kept and tagged with whatever
    district the source says it came from. This single helper handles both
    the "single district" and "all Karnataka" live-data paths, so the
    filtering logic exists in exactly one place.
    """
    parsed: list[dict] = []
    for rec in records:
        commodity = rec.get("commodity") or rec.get("Commodity")
        modal = rec.get("modal_price") or rec.get("Modal_Price")
        market = rec.get("market") or rec.get("Market")
        rec_district = (
            rec.get("district")
            or rec.get("District")
            or (filter_district or "")
        )

        if not commodity or not modal or not market:
            continue
        try:
            modal_val = float(modal)
        except (TypeError, ValueError):
            continue
        if modal_val <= 0:
            continue

        rec_district_str = str(rec_district).strip()
        if (
            filter_district is not None
            and rec_district_str.lower() != filter_district.lower()
        ):
            continue

        parsed.append({
            "district": rec_district_str.title() or (filter_district or "Karnataka"),
            "crop": str(commodity).strip(),
            "modal_price": f"₹{int(modal_val)} / Qtl",
            "mandi": str(market).strip(),
        })
    return parsed


async def _fetch_live_rates(
    api_key: str,
    district: Optional[str],
) -> Optional[list[dict]]:
    """
    Try to fetch live Agmarknet rates from Data.gov.in.

    Returns the parsed list on success, or None on any failure. `district`
    = None means "all Karnataka". Failures are logged and swallowed; the
    caller falls back to mock data.
    """
    try:
        async with httpx.AsyncClient(timeout=25.0) as client:
            params = {
                "api-key": api_key,
                "format": "json",
                # All-mode asks for a bigger page — the whole state's
                # rate table is bigger than any one district's.
                "limit": 500 if district is None else 100,
                "filters[state.keyword]": "Karnataka",
            }
            if district is not None:
                params["filters[district]"] = district

            resp = await client.get(
                _DATA_GOV_BASE_URL,
                params=params,
                headers={"User-Agent": _OVERPASS_USER_AGENT},
            )
            print(f"[mandi-rates] filtered status={resp.status_code}")
            resp.raise_for_status()
            payload = resp.json()
            records = (
                payload.get("records") if isinstance(payload, dict) else None
            )

            # Unfiltered fallback: some districts return zero rows on the
            # filtered endpoint even though they're present in the state
            # feed. Retry without the district filter and match client-side.
            # (Skipped for all-mode — that request is already unfiltered.)
            if not records and district is not None:
                print(
                    "[mandi-rates] filtered returned nothing, retrying "
                    "unfiltered..."
                )
                resp2 = await client.get(
                    _DATA_GOV_BASE_URL,
                    params={
                        "api-key": api_key,
                        "format": "json",
                        "limit": 500,
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
                records = [
                    r for r in all_records
                    if (r.get("state") or r.get("State") or "")
                    .strip().lower() == "karnataka"
                ]

            if not records:
                print("[mandi-rates] No records found in Data.gov API response.")
                return None

            parsed = _parse_live_records(records, filter_district=district)
            return parsed if parsed else None
    except httpx.HTTPError as e:
        print(f"[mandi-rates] HTTP error: {type(e).__name__}: {e}")
        if hasattr(e, "response") and e.response is not None:
            print(f"[mandi-rates] response body: {e.response.text[:500]}")
        return None
    except Exception as e:
        print(f"[mandi-rates] unexpected error: {type(e).__name__}: {e}")
        return None


@app.get("/mandi-rates/")
async def get_mandi_rates(
    district: Optional[str] = Query(
        None,
        max_length=80,
        description=(
            "District name, or omit for all Karnataka. Also accepts "
            "'All Karnataka' / 'all' as sentinel values."
        ),
    ),
):
    """
    Today's modal mandi prices for a Karnataka district — or all of them.

    Tries Data.gov.in's Agmarknet resource first when DATA_GOV_API_KEY is
    set; falls back to a small local mock dataset on any failure.

    ## Response shape

      {
        "status": "success",
        "source": "live" | "mock",
        "selected_district": "Kolar" | null,
        "available_districts": ["Bagalkot", ..., "Vijayanagara"],
        "rates": [
          {
            "district": "Kolar",
            "crop": "Tomato",
            "modal_price": "₹2200 / Qtl",
            "mandi": "Kolar APMC"
          },
          ...
        ]
      }

    ## "All Karnataka" mode

    Omitting `district` — or sending `district=All Karnataka` — returns
    rates across every district in one call. The client can then sort and
    filter the merged list entirely client-side without fanning out to
    per-district requests. `selected_district` is `null` in this mode.

    ## Unknown districts

    An unrecognized `district` returns `rates: []` rather than silently
    substituting Kolar's data under a misleading label. The client's empty
    state is the honest surface.
    """
    selected = _normalize_district_filter(district or "")

    api_key = os.environ.get("DATA_GOV_API_KEY")
    live_rates: Optional[list[dict]] = None
    if api_key:
        live_rates = await _fetch_live_rates(api_key, selected)

    if live_rates:
        rates = live_rates
        source = "live"
    else:
        if selected is None:
            # All-Karnataka: merge every district's mock rates into one
            # flat list. Each entry carries its own `district` field so
            # the client can render it if it wants.
            rates = []
            for d in _MANDI_RATE_DISTRICTS:
                rates.extend(_mock_rates_for(d))
        else:
            rates = _mock_rates_for(selected)
        source = "mock"

    return {
        "status": "success",
        "source": source,
        "selected_district": selected,
        "available_districts": _MANDI_RATE_DISTRICTS,
        "rates": rates,
    }


# ---------------------------------------------------------------------------
# Dual-source market listing (APMC_YARD + LOCAL_MARKET)
# ---------------------------------------------------------------------------

async def _fetch_apmc_yards(district_clean: str) -> list[dict]:
    """
    Return the official APMC yards registered under `district_clean`.

    Data Source B for `/mandi/markets`. Tries Data.gov.in / Agmarknet
    first (via the existing `_fetch_live_rates` helper); falls back to
    the local `_MOCK_MANDI_RATES` dataset if the live call fails or
    `DATA_GOV_API_KEY` is unset.

    Each entry is shaped to match the merged `/mandi/markets` response:

        {
          "id":       "apmc::<lowercased name>",
          "name":     "Kolar APMC",
          "type":     "APMC_YARD",
          "district": "Kolar",
          "address":  None,
          "lat":      None,
          "lng":      None,
        }

    Only rows whose `mandi` name contains "APMC" (case-insensitive) are
    included — the Agmarknet `market` field also carries vegetable /
    fish market names, and those belong to the LOCAL_MARKET source.
    """
    yards: list[dict] = []
    seen: set[str] = set()

    def _add(name: str) -> None:
        cleaned = name.strip()
        if not cleaned:
            return
        key = cleaned.lower()
        if key in seen:
            return
        seen.add(key)
        yards.append({
            "id": f"apmc::{key}",
            "name": cleaned,
            "type": "APMC_YARD",
            "district": district_clean,
            "address": None,
            "lat": None,
            "lng": None,
        })

    # Try the live Agmarknet feed first.
    api_key = os.environ.get("DATA_GOV_API_KEY")
    if api_key:
        live = await _fetch_live_rates(api_key, district_clean)
        if live:
            for r in live:
                mandi_name = (r.get("mandi") or "").strip()
                if not mandi_name:
                    continue
                if "apmc" not in mandi_name.lower():
                    continue
                _add(mandi_name)

    # Fall back to mock APMC data if live data yielded nothing.
    if not yards:
        for r in _mock_rates_for(district_clean):
            mandi_name = (r.get("mandi") or "").strip()
            if not mandi_name:
                continue
            if "apmc" not in mandi_name.lower():
                continue
            _add(mandi_name)

    return yards


@app.get(
    "/mandi/markets",
    summary="Dual-source market listing (APMC yards + local markets)",
)
async def list_mandi_markets(
    district: str = Query(
        ..., min_length=1, max_length=80,
        description="Karnataka district name.",
    ),
):
    """
    Unified market listing for a Karnataka district, combining two
    independent data sources.

    ## Data sources

    **Source A — Local markets (`LOCAL_MARKET`)**

        The existing OpenStreetMap / Overpass lookup (`/mandis/search`),
        which catches town markets, fish markets, and regional yards
        that aren't on the official APMC register — e.g.
        "Manjeshwar Fish Market".

    **Source B — Official APMC yards (`APMC_YARD`)**

        The Agmarknet / Data.gov.in register for the district, filtered
        to entries whose market name contains "APMC" — e.g.
        "Bantwala APMC", "Puttur APMC". Falls back to the local mock
        dataset when the live API is unavailable or has no coverage.

    ## Merge & deduplicate

    Both sources are merged into one array and deduplicated by
    case-insensitive market name. APMC yards are emitted first (official
    data before heuristic web-scraped data), then local markets — so the
    dropdown in the Book Transport screen shows the government-listed
    destinations at the top.

    Each item carries a `type` field so the client can badge the entry:

      - `APMC_YARD`     — official government mandi.
      - `LOCAL_MARKET`  — local town / fish / regional market.

    ## Response shape

      {
        "district": "Kolar",
        "markets": [
          {
            "id":       "apmc::kolar apmc",
            "name":     "Kolar APMC",
            "type":     "APMC_YARD",
            "district": "Kolar",
            "address":  null,
            "lat":      null,
            "lng":      null
          },
          {
            "id":       "local::manjeshwar fish market",
            "name":     "Manjeshwar Fish Market",
            "type":     "LOCAL_MARKET",
            "district": "Kolar",
            "address":  "Manjeshwar, Kolar, Karnataka",
            "lat":      12.7145,
            "lng":      74.8823
          }
        ]
      }

    ## Error handling

    If Overpass is down, the endpoint still returns the APMC results
    (with `markets` containing only `APMC_YARD` entries) rather than
    surfacing a 502. An unknown district raises a 400 before either
    source is queried.
    """
    district_clean = district.strip()
    if district_clean not in _DISTRICT_CENTERS:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown district: {district_clean}",
        )

    # Source B — official APMC yards (Agmarknet / mock fallback).
    apmc_entries = await _fetch_apmc_yards(district_clean)

    # Source A — local markets via Overpass. Failures here are swallowed
    # so the APMC results still reach the client.
    try:
        local_markets = await _overpass_search_local_markets(district_clean)
    except HTTPException:
        local_markets = []

    local_entries: list[dict] = []
    for m in local_markets:
        name = (m.get("name") or "").strip()
        if not name:
            continue
        local_entries.append({
            "id": f"local::{name.lower()}",
            "name": name,
            "type": "LOCAL_MARKET",
            "district": district_clean,
            "address": m.get("address"),
            "lat": m.get("lat"),
            "lng": m.get("lng"),
        })

    # Merge & deduplicate by case-insensitive name. APMC yards come
    # first, so an entry like "Kolar APMC" that Overpass also picked up
    # will be served from the APMC branch (correct type label).
    seen_names: set[str] = set()
    merged: list[dict] = []
    for entry in apmc_entries + local_entries:
        key = entry["name"].strip().lower()
        if not key or key in seen_names:
            continue
        seen_names.add(key)
        merged.append(entry)

    return {"district": district_clean, "markets": merged}


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
    summary="Update basic profile info (name, phone, district, taluk/village)",
)
def update_farmer_profile(
    payload: schemas.FarmerProfileUpdate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Update the name, contact phone, and location fields.

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
# Farmer Saved Addresses (pickup bookmarks)
# ---------------------------------------------------------------------------

@app.get(
    "/farmer/addresses",
    response_model=List[schemas.SavedAddressOut],
    summary="List the farmer's saved pickup addresses",
)
def list_farmer_addresses(
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Return the farmer's saved pickup locations, newest first.

    Drives the "Saved Places" chip row in the Book Transport form. An
    empty list is normal and valid — the client renders the two
    remaining pickup options (Current GPS / Manual Entry) in that case.
    """
    return crud.get_saved_addresses_for_farmer(db, current_user.id)


@app.post(
    "/farmer/addresses",
    response_model=schemas.SavedAddressOut,
    status_code=201,
    summary="Create a saved pickup address",
)
def create_farmer_address(
    payload: schemas.SavedAddressCreate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Manually save a pickup location. Independent of any booking.

    The auto-save path (booking with `save_address_for_future=True`)
    doesn't go through this endpoint — it's a side effect inside
    `crud.create_produce_request` — but both write the same row shape
    and appear in the same GET response.
    """
    try:
        return crud.create_saved_address(
            db,
            current_user.id,
            title=payload.title,
            address_text=payload.address_text,
            landmark=payload.landmark,
            latitude=payload.latitude,
            longitude=payload.longitude,
        )
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Farmer Orders — Order History + Single-order Detail + Create
# ---------------------------------------------------------------------------
#
# NOTE ON ROUTE ORDERING: `/farmer/orders/history` is declared BEFORE
# `/farmer/orders/{order_id}`. FastAPI matches routes in registration
# order, and the path converter for `{order_id}` is UUID — "history" is
# not a UUID, so if the parameterized route were registered first, the
# history request would 422 on UUID validation instead of falling through.
# Do not reorder these two decorators.
#
# `/farmer/orders/create` is declared AFTER `/farmer/orders/{order_id}`
# because it uses the POST method, which the parameterized GET route
# doesn't match anyway. Placed here so the whole "orders" family stays
# together in the file.
# ---------------------------------------------------------------------------

@app.get(
    "/farmer/orders/history",
    response_model=List[schemas.OrderHistoryItemResponse],
    summary="List the authenticated farmer's order history (summary view)",
)
def get_farmer_order_history(
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Return every order belonging to the authenticated farmer, newest
    first, in the compact 3-line summary shape the Order History list
    renders.

    Includes orders in every lifecycle state (PENDING, IN_TRANSIT,
    COMPLETED, CANCELLED) — the client shows all of them so a farmer can
    see in-flight shipments alongside their past ones.

    Fields returned per row:
      id, crop_name, weight_kg, status, created_at,
      pickup_village, mandi_name, stall_number

    `status` is normalized (PENDING / IN_TRANSIT / COMPLETED / CANCELLED).
    `pickup_village` and `mandi_name` / `stall_number` are derived
    server-side from the stored fields — the structured `dropoff_mandi_name`
    / `dropoff_stall_number` columns when populated, or parsed out of the
    legacy composite `dropoff_location` string otherwise. See
    `crud.get_farmer_order_history` for the derivation rules.
    """
    try:
        return crud.get_farmer_order_history(db, current_user.id)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get(
    "/farmer/orders/{order_id}",
    response_model=schemas.FarmerOrderDetailResponse,
    summary="Get full nested details for a single farmer order",
)
def get_farmer_order_detail(
    order_id: UUID,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Return the full nested detail view for one order owned by the
    authenticated farmer.

    Response shape (see FarmerOrderDetailResponse for the full doc):

      - id / status / trip_status / created_at / completed_at
        drive the header and the 4-step status timeline.
      - rider         — None while no rider has accepted.
      - pickup        — pickup address block (lat/lng when available).
      - dropoff       — APMC mandi + stall block.
      - crop          — crop type and weight.
      - settlement    — None until the trip is DELIVERED (settlement is
                        auto-created by the trip status transition).

    404 if the order doesn't exist OR belongs to a different farmer —
    order existence is deliberately not leaked across accounts.
    """
    result = crud.get_farmer_order_detail(db, order_id, current_user.id)
    if result is None:
        raise HTTPException(status_code=404, detail="Order not found")
    return result


@app.post(
    "/farmer/orders/create",
    response_model=schemas.ProduceRequestResponse,
    status_code=201,
    summary="Create a farmer order (alias for POST /produce-requests/)",
)
def create_farmer_order(
    request: schemas.ProduceRequestCreate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Create a produce pickup request for the authenticated farmer.

    Naming alias for `POST /produce-requests/` that matches the URL
    convention used by the other `/farmer/orders/*` endpoints. Same
    payload, same behavior, same response shape.

    ## Payload

    Accepts `schemas.ProduceRequestCreate`, whose fields map to the
    Book Transport form's inputs:

      - `weight_kg`                 — total weight in kilograms (sole
                                      quantity metric; `crate_count`
                                      was removed by the refactor).
      - `latitude` / `longitude`    — the pickup location's coordinates
                                      (required — PostGIS needs them).
      - `pickup_address`            — human-readable pickup address the
                                      farmer typed or selected from a
                                      saved place (optional).
      - `pickup_landmark`           — short landmark line (optional).
      - `dropoff_district`          — target district.
      - `dropoff_mandi_id` and/or `dropoff_mandi_name` — the market
                                      destination. `dropoff_mandi_id`
                                      is a stable identifier from
                                      GET /mandi/markets; `dropoff_mandi_name`
                                      is the display name.
      - `dropoff_stall_number`      — optional stall / shop / bay.

    ## What happens on success

    1. A ProduceRequest row is created with `status="PENDING"` and a
       fresh 4-digit pickup OTP.
    2. If `save_address_for_future=True` and a non-empty
       `pickup_address` was supplied, the address is also persisted to
       SavedAddress.
    3. The response carries the full ProduceRequest shape (including the
       structured dropoff fields). The pickup OTP is exposed via the
       FarmerProduceRequestResponse shape on subsequent GETs.
    """
    try:
        return crud.create_produce_request(db, request, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Farmer Order Edit + Cancel
# ---------------------------------------------------------------------------
# Both endpoints are locked to PENDING orders. Once a rider has accepted,
# the order cannot be modified or cancelled — the trip is already in motion
# and the rider has committed real resources toward the pickup. Both
# endpoints return 400 with the same canonical message on a locked order.
# ---------------------------------------------------------------------------


@app.put(
    "/farmer/orders/{order_id}",
    response_model=schemas.FarmerOrderDetailResponse,
    summary="Update a PENDING farmer order",
)
def update_farmer_order(
    order_id: UUID,
    payload: schemas.FarmerOrderUpdate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Partially update a PENDING order owned by the authenticated farmer.

    Only PENDING orders can be modified. Once a rider has accepted the
    order, this endpoint returns 400 with:

        "Order cannot be modified or cancelled after acceptance"

    Accepted fields (all optional):
      - crop_name
      - weight_kg
      - dropoff_district
      - dropoff_mandi
      - dropoff_stall_number
      - pickup_notes
    """
    updates = payload.model_dump(exclude_unset=True)

    if "crop_name" in updates and updates["crop_name"] is not None:
        updates["crop_name"] = updates["crop_name"].strip()
        if not updates["crop_name"]:
            raise HTTPException(
                status_code=400, detail="crop_name cannot be empty"
            )

    try:
        crud.update_farmer_order(db, order_id, current_user.id, updates)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))

    try:
        result = crud.get_farmer_order_detail(db, order_id, current_user.id)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database sync error: {str(e)}")
        
    if result is None:
        raise HTTPException(status_code=404, detail="Order not found")
    return result


@app.post(
    "/farmer/orders/{order_id}/cancel",
    response_model=schemas.FarmerOrderDetailResponse,
    summary="Cancel a PENDING farmer order",
)
def cancel_farmer_order(
    order_id: UUID,
    payload: Optional[schemas.FarmerOrderCancel] = None,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Cancel a PENDING order owned by the authenticated farmer.

    Body is optional; when present, `cancellation_reason` is stored on
    the order row for support/audit purposes.

    Only PENDING orders can be cancelled. Once a rider has accepted the
    order, this endpoint returns 400 with:

        "Order cannot be modified or cancelled after acceptance"

    ## Error handling

    `ValueError` from the CRUD layer (order not found / not PENDING /
    not owned by this farmer) is surfaced as a 400. Any raw
    `SQLAlchemyError` — the kind of driver-level failure that used to
    crash the request with a 500 stack trace — is rolled back inside the
    CRUD layer and translated here into a fixed, user-safe 500 message.
    The driver error text itself is never returned to the client.

    On success the order's status flips to CANCELLED and the updated
    order detail is returned so the client can render the "cancelled"
    banner without a second GET.
    """
    reason = payload.cancellation_reason if payload else None

    try:
        crud.cancel_farmer_order(db, order_id, current_user.id, reason)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except SQLAlchemyError:
        # Do NOT forward the driver message. Raw SQL / table names must
        # never leave the server.
        raise HTTPException(status_code=500, detail="Failed to cancel order")

    try:
        result = crud.get_farmer_order_detail(db, order_id, current_user.id)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database sync error: {str(e)}")

    if result is None:
        raise HTTPException(status_code=404, detail="Order not found")
    return result


# ---------------------------------------------------------------------------
# Rider Account
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
    preferences.
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
    summary="Update basic rider profile info (name, phone, district)",
)
def update_rider_profile(
    payload: schemas.RiderProfileUpdate,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Update the rider's name, contact phone, and district.

    `email` is intentionally NOT updatable here — same reasoning as the
    farmer profile endpoint.
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
    normalizes whitespace and strips empty entries.
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
    verification runs here.
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
# Rider Trips — Trip History + Active List + Single-trip Detail + Actions
# ---------------------------------------------------------------------------
#
# ROUTE ORDERING (important): static sub-paths under `/rider/trips/` must
# be declared BEFORE the `/rider/trips/{trip_id}` parameterized route,
# because FastAPI matches routes in registration order and a UUID path
# converter will reject "history" and "active" as 422s.
#
#   /rider/trips/history   ✅ registered first
#   /rider/trips/active    ✅ registered second
#   /rider/trips/{trip_id} ✅ registered last
#
# The two POST action routes (`/verify-otp`, `/cancel`) use their own
# full paths with the `{trip_id}` parameter, so they don't collide with
# the GET parameterized route at all.
# ---------------------------------------------------------------------------

@app.get(
    "/rider/trips/history",
    response_model=List[schemas.RiderTripHistoryItemResponse],
    summary="List the rider's completed and cancelled trips (summary view)",
)
def get_rider_trip_history(
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Return every DELIVERED or CANCELLED trip assigned to the
    authenticated rider, newest first, in the compact 4-line summary
    shape the Trip History list renders.

    Active trips (ACCEPTED, PICKED_UP) are deliberately excluded — the
    rider's Active Trips tab is the right place for those, and this
    screen is framed as a *history* of completed work.

    Fields returned per row:
      id, crop_name, weight_kg, fare_earned, status, created_at,
      pickup_village, mandi_name, stall_number, payment_method

    `payment_method` is "Wallet Credited" (settlement PAID) or
    "Cash Collected" (settlement still PENDING); it's "—" for cancelled
    trips. `pickup_village` and `mandi_name` / `stall_number` are
    derived server-side from the stored fields — see
    `crud.get_rider_trip_history` for the derivation rules.
    """
    try:
        return crud.get_rider_trip_history(db, current_user.id)
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Rider Active Trips — compact list + operational actions
# ---------------------------------------------------------------------------
# These endpoints back the refactored rider "Active Trips" tab, which
# shows a unified list of ACCEPTED / PICKED_UP / COMPLETED trips with
# status filter chips, and pushes all operational actions (verify OTP,
# cancel, mark delivered) into the trip detail view.
# ---------------------------------------------------------------------------

# How far back the Active list will surface COMPLETED trips. Keeping this
# short means the feed stays focused on recent operational work — the
# full historical record lives in `/rider/trips/history`.
_RIDER_ACTIVE_COMPLETED_LOOKBACK_DAYS = 30


@app.get(
    "/rider/trips/active",
    summary="Rider's active and recently completed trips (compact list view)",
)
def get_rider_active_trips_compact(
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Return the rider's ACCEPTED / PICKED_UP / IN_TRANSIT / COMPLETED
    trips in the compact shape the refactored Active Trips list view
    renders.

    ## Status normalization

    Two different underlying statuses map to the same client-facing
    status so the filter chips stay a small, closed set:

      ACCEPTED      → "ACCEPTED"
      PICKED_UP     → "PICKED_UP"
      IN_TRANSIT    → "PICKED_UP"
      DELIVERED     → "COMPLETED"
      COMPLETED     → "COMPLETED"

    `raw_status` is also included so callers that care about the exact
    backend status (e.g. logging/analytics) can still see it.

    ## Completed trip lookback

    Only COMPLETED trips whose `completed_at` falls within the last
    `_RIDER_ACTIVE_COMPLETED_LOOKBACK_DAYS` days are returned. Full
    history lives at `/rider/trips/history`.

    ## Fields

    Every field the list card AND the detail sheet need is returned
    here in one call, so the operational sheet can render without a
    second network round-trip:

      order_id            — the Trip's UUID
      produce_request_id  — the ProduceRequest's UUID
      crop_name, weight_kg
      dropoff_mandi, dropoff_stall, dropoff_address
      pickup_address, pickup_landmark, pickup_latitude, pickup_longitude
      status (normalized), raw_status
      created_at, completed_at
      farmer_full_name, farmer_phone_number, farm_address
    """
    cutoff = datetime.utcnow() - timedelta(
        days=_RIDER_ACTIVE_COMPLETED_LOOKBACK_DAYS
    )

    try:
        trips = (
            db.query(models.Trip)
            .options(
                joinedload(models.Trip.produce_request).joinedload(
                    models.ProduceRequest.farmer
                ),
                joinedload(models.Trip.rider),
            )
            .filter(
                models.Trip.rider_id == current_user.id,
                or_(
                    models.Trip.status.in_(
                        ("ACCEPTED", "PICKED_UP", "IN_TRANSIT")
                    ),
                    and_(
                        models.Trip.status.in_(("COMPLETED", "DELIVERED")),
                        or_(
                            models.Trip.completed_at.is_(None),
                            models.Trip.completed_at >= cutoff,
                        ),
                    ),
                ),
            )
            .order_by(models.Trip.created_at.desc())
            .all()
        )
    except SQLAlchemyError as e:
        raise HTTPException(status_code=400, detail=str(e))

    result: list[dict] = []
    for trip in trips:
        pr = trip.produce_request
        if pr is None:
            continue

        farmer = pr.farmer

        # Resolve pickup lat/lng from the Trip's snapshot, with a
        # ProduceRequest fallback for older rows.
        pickup_lat = trip.pickup_latitude
        pickup_lng = trip.pickup_longitude
        if pickup_lat is None and pr.pickup_location is not None:
            try:
                from geoalchemy2.shape import to_shape as _to_shape
                point = _to_shape(pr.pickup_location)
                pickup_lat = float(point.y)
                pickup_lng = float(point.x)
            except Exception:
                pass

        # Normalize status for the client. See the endpoint docstring.
        raw = (trip.status or "").upper()
        if raw in ("COMPLETED", "DELIVERED"):
            display_status = "COMPLETED"
        elif raw in ("PICKED_UP", "IN_TRANSIT"):
            display_status = "PICKED_UP"
        else:
            display_status = raw or "ACCEPTED"

        result.append({
            "order_id": str(trip.id),
            "produce_request_id": str(pr.id),
            "crop_name": pr.crop_type or "—",
            "weight_kg": float(pr.weight_kg or 0),
            "dropoff_mandi": (
                pr.dropoff_mandi_name
                or pr.dropoff_location
                or "—"
            ),
            "dropoff_stall": pr.dropoff_stall_number,
            "dropoff_address": pr.dropoff_location,
            "pickup_address": (
                trip.pickup_address or pr.pickup_address
            ),
            "pickup_landmark": (
                trip.pickup_landmark or pr.pickup_landmark
            ),
            "pickup_latitude": pickup_lat,
            "pickup_longitude": pickup_lng,
            "status": display_status,
            "raw_status": trip.status,
            "created_at": (
                trip.created_at.isoformat()
                if trip.created_at is not None else None
            ),
            "completed_at": (
                trip.completed_at.isoformat()
                if trip.completed_at is not None else None
            ),
            "farmer_full_name": farmer.full_name if farmer else None,
            "farmer_phone_number": (
                farmer.phone_number if farmer else None
            ),
            "farm_address": (
                (farmer.farm_address or farmer.landmark)
                if farmer else None
            ),
        })

    return result


@app.get(
    "/rider/trips/{trip_id}",
    response_model=schemas.RiderTripDetailResponse,
    summary="Get full nested details for one of the rider's trips",
)
def get_rider_trip_detail(
    trip_id: UUID,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Return the full nested detail view for one of the authenticated
    rider's trips.

    Response shape (see RiderTripDetailResponse for the full doc):

      - id / status / completed_at / distance_km
        drive the completion header (delivery timestamp + distance).
      - farmer        — name, phone, farm address.
      - pickup        — pickup address block (lat/lng when available).
      - mandi         — APMC mandi + stall number (sourced from the
                        structured dropoff columns on new rows, or
                        parsed out of the legacy composite string on
                        older rows).
      - crop          — crop type and weight.
      - fare          — fare breakdown (gross, commission, net) plus
                        payment mode. None for CANCELLED trips.

    404 if the trip doesn't exist OR belongs to a different rider —
    trip existence is deliberately not leaked across accounts.
    """
    result = crud.get_rider_trip_detail(db, trip_id, current_user.id)
    if result is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    return result


@app.post(
    "/rider/trips/{trip_id}/verify-otp",
    summary="Verify pickup OTP for a rider's ACCEPTED trip",
)
def verify_rider_trip_otp(
    trip_id: UUID,
    body: schemas.OtpVerifyRequest,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Verify the 4-digit pickup OTP for a trip assigned to the authenticated
    rider, and on a match transition BOTH the linked `Trip` and the
    underlying `ProduceRequest` to `PICKED_UP`.

    ## Pre-conditions

    - The trip must exist and be assigned to the caller (403 otherwise).
    - The trip must currently be `ACCEPTED`. A trip already `PICKED_UP`
      or `COMPLETED` cannot be re-verified — this is the same idempotency
      guard the farmer-side endpoint enforces.

    ## Failure modes

    - 400 if the OTP doesn't match (`"Invalid OTP"`) or if the
      ProduceRequest is in a terminal state.
    - 403 if the caller isn't the assigned rider.
    - 404 if the trip doesn't exist.

    ## On success

    Both writes happen inside the existing CRUD helpers, which each
    wrap their row in `with_for_update()` and roll back on error:

      1. `crud.verify_pickup_otp` validates the OTP and flips
         `ProduceRequest.status` to `PICKED_UP`.
      2. `crud.update_trip_status` flips `Trip.status` to `PICKED_UP`.

    If step 1 succeeds but step 2 fails, the caller can retry — the
    ProduceRequest is already `PICKED_UP`, and the same idempotency
    guard on `update_trip_status` only rejects terminal states, so
    re-running the transition is safe.

    Returns a small JSON envelope rather than a full trip payload,
    because the rider's list is refreshed separately by the client.
    """
    trip = crud.get_trip_by_id(db, trip_id)
    if trip is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    if trip.rider_id != current_user.id:
        raise HTTPException(
            status_code=403,
            detail="You are not the rider assigned to this trip",
        )
    if trip.status != "ACCEPTED":
        raise HTTPException(
            status_code=400,
            detail=(
                "Trip must be ACCEPTED before OTP verification "
                f"(current: {trip.status})"
            ),
        )

    # ----- Step 1: validate OTP + flip ProduceRequest to PICKED_UP --------
    try:
        pr = crud.verify_pickup_otp(db, trip.produce_request_id, body.otp)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))
    if pr is None:
        raise HTTPException(
            status_code=404,
            detail="Linked produce request not found",
        )

    # ----- Step 2: flip the Trip to PICKED_UP ----------------------------
    try:
        crud.update_trip_status(db, trip_id, "PICKED_UP")
    except (SQLAlchemyError, ValueError) as e:
        # ProduceRequest is already PICKED_UP — surface the failure so
        # the client can retry the status sync.
        raise HTTPException(status_code=400, detail=str(e))

    return {
        "success": True,
        "message": "OTP verified successfully",
        "trip_id": str(trip_id),
        "new_status": "PICKED_UP",
    }


@app.post(
    "/rider/trips/{trip_id}/cancel",
    summary="Cancel an ACCEPTED rider trip (before OTP verification)",
)
def cancel_rider_trip(
    trip_id: UUID,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Cancel a trip the rider has accepted but not yet picked up.

    ## Allowed ONLY when `Trip.status == "ACCEPTED"`

    Once the pickup OTP has been verified (`PICKED_UP`) or the trip has
    been delivered (`COMPLETED` / `DELIVERED`), cancellation is locked —
    returning HTTP 400 with `"Cannot cancel trip after OTP verification"`.
    This protects the farmer: after the rider physically loads the
    produce, silently backing out would strand their shipment.

    ## What happens on success

    Inside one `try / commit / except rollback` block:

      1. `Trip.status` → `CANCELLED`, `Trip.completed_at` → now.
      2. `ProduceRequest.status` → `PENDING` so another rider can pick
         it up from the Available feed.

    The whole operation is transactional — if either the Trip update or
    the ProduceRequest revert fails, `db.rollback()` is called and the
    request returns a fixed, user-safe 500 message.

    Returns a small JSON envelope rather than a full trip payload,
    because the rider's list is refreshed separately by the client.
    """
    trip = crud.get_trip_by_id(db, trip_id)
    if trip is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    if trip.rider_id != current_user.id:
        raise HTTPException(
            status_code=403,
            detail="You are not the rider assigned to this trip",
        )
    if trip.status != "ACCEPTED":
        # Any status other than ACCEPTED is a hard 400 — the client
        # knows it should hide the cancel button in those states, so
        # reaching this branch indicates either a race or a stale view.
        raise HTTPException(
            status_code=400,
            detail="Cannot cancel trip after OTP verification",
        )

    try:
        # Lock the trip row so a concurrent status PATCH can't slip
        # between the check above and the write below.
        locked_trip = (
            db.query(models.Trip)
            .filter(models.Trip.id == trip_id)
            .with_for_update()
            .first()
        )
        if locked_trip is None:
            raise HTTPException(status_code=404, detail="Trip not found")
        if locked_trip.status != "ACCEPTED":
            # Lost the race — someone else transitioned the trip.
            raise HTTPException(
                status_code=400,
                detail="Cannot cancel trip after OTP verification",
            )

        locked_trip.status = "CANCELLED"
        locked_trip.completed_at = datetime.utcnow()

        # Revert the ProduceRequest to PENDING so another rider can
        # accept it. If the row is missing (shouldn't happen — FK is
        # NOT NULL), we still complete the cancel on the Trip side.
        linked_pr = (
            db.query(models.ProduceRequest)
            .filter(
                models.ProduceRequest.id
                == locked_trip.produce_request_id
            )
            .with_for_update()
            .first()
        )
        if linked_pr is not None:
            linked_pr.status = "PENDING"

        db.commit()
        db.refresh(locked_trip)
    except HTTPException:
        # Re-raise 400/404 we generated above without double-wrapping.
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise HTTPException(
            status_code=500, detail="Failed to cancel trip"
        )

    return {
        "success": True,
        "message": "Trip cancelled",
        "trip_id": str(trip_id),
    }


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

    ## Quantity metric

    The payload now uses `weight_kg` as the sole quantity field —
    `crate_count` was removed by the Book Transport refactor. Fare,
    surcharge, and settlement math are keyed off weight.

    ## Pickup

    The pickup fields (`pickup_address`, `pickup_landmark`) capture what
    the farmer entered in the 3-way pickup picker (Current GPS / Saved
    Places / Manual Entry). When `save_address_for_future=True`, the
    address is also bookmarked for reuse — see crud.create_produce_request.

    ## Dropoff

    Structured dropoff fields (`dropoff_district`, `dropoff_mandi_id`,
    `dropoff_mandi_name`, `dropoff_stall_number`) are accepted and
    persisted directly. The legacy `dropoff_location` string is derived
    server-side when only the structured fields were supplied, so older
    display code keeps working.
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
    """
    Return PENDING produce requests within radius_km of the given point.

    NOTE: this is the legacy browse feed. For the privacy-safe rider feed
    that withholds farmer contact info, use `GET /trips/available`.
    """
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
    PENDING), not a Trip. Same behaviour as POST /produce-requests/ —
    including the pickup-address persistence and the
    `save_address_for_future` side effect.

    Quantity is `weight_kg` (kilograms); structured dropoff fields are
    persisted as-is, and the legacy `dropoff_location` string is derived
    server-side when only the structured fields were sent.
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


# ---------------------------------------------------------------------------
# Privacy-aware trip browsing + acceptance
# ---------------------------------------------------------------------------
#
# The rider-facing UI calls trips "trips" and the farmer-facing UI calls
# them "orders", but both refer to the same ProduceRequest row. A Trip
# row only exists AFTER a rider accepts — so a `trip_id` in the URLs
# below is the ProduceRequest's id when the trip is still PENDING, and
# the Trip's id once accepted. Clients should use `produce_request_id`
# from TripActiveOut for stable cross-lookups.
# ---------------------------------------------------------------------------

@app.get(
    "/trips/available",
    response_model=List[schemas.TripAvailableOut],
    summary="Browse pending trips near the rider (farmer contact hidden)",
)
def list_available_trips(
    lat: float = Query(..., ge=-90, le=90, description="Rider's current latitude"),
    lng: float = Query(..., ge=-180, le=180, description="Rider's current longitude"),
    radius_km: float = Query(10, gt=0, le=200, description="Search radius in kilometers"),
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
) -> List[schemas.TripAvailableOut]:
    """
    Return PENDING trips within radius_km, shaped for the rider-facing
    browse feed.

    ## Privacy

    The farmer's phone number is never included in this view. Only the
    farmer's first name is surfaced, so the rider has a human reference
    without an identifier they can act on out of band. Contact details
    unlock the moment the rider accepts — see `POST /trips/{trip_id}/accept`.

    ## Pickup address

    The pickup address/landmark are exposed pre-acceptance — the rider
    needs them to decide whether the trip is worth taking, and neither
    is a sensitive identifier in the way a phone number is.
    """
    try:
        return crud.get_available_trips_for_rider(
            db, lat=lat, lng=lng, radius_km=radius_km
        )
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post(
    "/trips/{trip_id}/accept",
    response_model=schemas.TripActiveOut,
    status_code=201,
    summary="Accept a pending trip (rider); returns contact-unlocked details",
)
def accept_trip_by_id(
    trip_id: UUID,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Accept a PENDING trip as the authenticated rider.

    ## About the `trip_id` parameter

    In the current data model a Trip row only exists AFTER a rider
    accepts — the thing being accepted is the ProduceRequest. So
    `trip_id` here is the ProduceRequest's id. The rider-facing client
    receives that id from `GET /trips/available` (as `trip_id`) and
    passes it straight back here — the mapping is transparent to
    consumers.

    ## What happens on success

    1. The ProduceRequest flips from PENDING to ACCEPTED.
    2. A new Trip row is created with `rider_id` bound to the caller and
       the ProduceRequest's pickup address/landmark/coordinates copied
       onto it as a snapshot.
    3. The response includes both parties' contact details, which are
       unlocked the moment a rider is assigned.

    ## Error cases

    - 400 if the request doesn't exist, is already accepted, or is in a
      terminal state.
    - 403 if the caller isn't a RIDER (handled by `require_role`).
    """
    try:
        trip = crud.accept_produce_request(db, trip_id, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))

    result = crud.get_trip_active_by_request_id(db, trip.produce_request_id)
    if result is None:
        raise HTTPException(status_code=404, detail="Order not found after accept")
    return result


@app.post(
    "/trips/accept",
    response_model=schemas.TripActiveOut,
    status_code=201,
    summary="Legacy alias for POST /trips/{trip_id}/accept",
)
def accept_trip_legacy(
    request_id: UUID = Query(..., description="ID of the produce request being accepted"),
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Legacy path for accepting a trip, kept for existing clients.

    Prefer `POST /trips/{trip_id}/accept` in new code. Both endpoints
    share the same behaviour and response shape.
    """
    try:
        trip = crud.accept_produce_request(db, request_id, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))

    result = crud.get_trip_active_by_request_id(db, trip.produce_request_id)
    if result is None:
        raise HTTPException(status_code=404, detail="Order not found after accept")
    return result


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


@app.get(
    "/trips/active",
    response_model=List[schemas.TripActiveOut],
    summary="The rider's active trips, with farmer contact info unlocked",
)
def get_active_trips(
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
) -> List[schemas.TripActiveOut]:
    """
    All of the authenticated rider's currently active trips (status
    ACCEPTED or PICKED_UP), newest first.

    Each entry carries the assigned farmer's phone number and full name,
    because a rider assigned to a trip needs to coordinate the pickup.

    ## Response shape change

    This endpoint previously returned `ActiveTripResponse` (with a
    nested `produce_request` object and an `id` field). It now returns
    the flat `TripActiveOut` shape with privacy-aware contact fields.
    Clients reading the old nested structure need to be updated.
    """
    return crud.get_active_trips_out_for_rider(db, current_user.id)


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