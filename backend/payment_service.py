"""
Payment, delivery-time mandi rate resolution, and QR code split service.

Design rules:
1. Crop rate is resolved AT DELIVERY TIME from the live Data.gov.in Agmarknet API
   (using DATA_GOV_API_KEY, matching Data.gov.in modal prices converted from Rs/Qtl to Rs/kg).
2. If DATA_GOV_API_KEY is missing, the live API is unavailable, or the entered crop is
   not listed in live mandi rates, the rate falls back to Rs 50.0/kg.
3. Supports both single-trip settlements and whole-pool single-QR payments
   (one QR for total crop value; atomic split marks every pool settlement PAID).
"""

from __future__ import annotations

import os
import re
import time
import uuid
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple
from uuid import UUID

import httpx
from sqlalchemy import text
from sqlalchemy.orm import Session, joinedload

import models


_DATA_GOV_BASE_URL = (
    "https://api.data.gov.in/resource/9ef84268-d588-465a-a308-a864a43d0070"
)
FALLBACK_RATE_PER_KG = 50.0
_LIVE_CACHE_TTL_SECONDS = 900  # 15 minutes — fresh daily mandi rates without slowdowns

# cache_key -> (monotonic_timestamp, parsed_records)
_LIVE_RATE_CACHE: Dict[str, Tuple[float, List[dict]]] = {}

# Common aliases & spelling variations so farmer crop text matches Agmarknet labels
_CROP_ALIASES: Dict[str, Tuple[str, ...]] = {
    "tomato": ("tomato", "tomatoes", "hybrid tomato", "local tomato", "desi tomato"),
    "onion": ("onion", "onions", "bellary", "small onion"),
    "potato": ("potato", "potatoes", "alu"),
    "carrot": ("carrot", "carrots"),
    "beans": ("beans", "bean", "french beans", "cluster beans"),
    "arecanut": ("arecanut", "areca", "betelnut", "supari", "chali"),
    "pepper": ("pepper", "black pepper", "kali mirch"),
    "tur": ("tur", "tur dal", "toor", "arhar", "red gram"),
    "paddy": ("paddy", "rice", "dhan"),
    "ragi": ("ragi", "finger millet"),
    "jowar": ("jowar", "sorghum"),
    "maize": ("maize", "corn"),
    "chilli": ("chilli", "chillies", "green chilli", "dry chillies", "red chilli"),
    "ginger": ("ginger", "ginger(green)"),
    "coconut": ("coconut", "tender coconut", "copra"),
    "cashew": ("cashew", "cashewnuts"),
    "banana": ("banana", "plantain"),
    "coffee": ("coffee", "arabica", "robusta"),
    "cardamom": ("cardamom", "elaichi"),
    "sugarcane": ("sugarcane", "cane"),
    "cotton": ("cotton", "kapas"),
    "soybean": ("soybean", "soya", "soyabean"),
    "sunflower": ("sunflower",),
    "grapes": ("grapes", "grape"),
    "mango": ("mango", "mangoes"),
}


def clear_rate_cache() -> None:
    """Reset in-memory live rate cache (mainly for deterministic tests)."""
    _LIVE_RATE_CACHE.clear()


def ensure_settlement_payment_columns(conn) -> None:
    """Idempotently add payment/QR columns to `settlements` on Postgres."""
    stmts = [
        "ALTER TABLE settlements ADD COLUMN IF NOT EXISTS rate_per_kg DOUBLE PRECISION;",
        "ALTER TABLE settlements ADD COLUMN IF NOT EXISTS rate_source VARCHAR(30);",
        "ALTER TABLE settlements ADD COLUMN IF NOT EXISTS qr_code_token VARCHAR(255);",
        "ALTER TABLE settlements ADD COLUMN IF NOT EXISTS qr_amount DOUBLE PRECISION;",
        "ALTER TABLE settlements ADD COLUMN IF NOT EXISTS payment_reference VARCHAR(120);",
        "ALTER TABLE settlements ADD COLUMN IF NOT EXISTS payment_method VARCHAR(40);",
        "ALTER TABLE settlements ADD COLUMN IF NOT EXISTS paid_at TIMESTAMPTZ;",
        "CREATE INDEX IF NOT EXISTS ix_settlements_qr_code_token ON settlements (qr_code_token);",
    ]
    for sql in stmts:
        conn.execute(text(sql))


def _normalize_crop_tokens(raw: str) -> List[str]:
    """Normalize a crop/commodity string into comparable tokens and canonical stem."""
    cleaned = re.sub(r"\([^)]*\)", " ", (raw or "").lower())
    cleaned = re.sub(r"[^a-z0-9\s]", " ", cleaned)
    words = [w for w in cleaned.split() if w]

    def _stem(word: str) -> str:
        if len(word) > 4 and word.endswith("es"):
            return word[:-2]
        if len(word) > 3 and word.endswith("s"):
            return word[:-1]
        return word

    stemmed = [_stem(w) for w in words]
    raw_compact = " ".join(stemmed).strip()
    tokens = list(dict.fromkeys([raw_compact] + stemmed + words))
    return [t for t in tokens if t]


def _crop_groups_for(crop_name: str) -> set[str]:
    tokens = set(_normalize_crop_tokens(crop_name))
    matched_groups: set[str] = set()
    for group_key, aliases in _CROP_ALIASES.items():
        alias_tokens = set()
        for a in aliases:
            alias_tokens.update(_normalize_crop_tokens(a))
        if tokens & alias_tokens:
            matched_groups.add(group_key)
    return matched_groups


def _crops_match(entered_crop: str, api_commodity: str) -> bool:
    if not entered_crop or not api_commodity:
        return False
    e_norm = re.sub(r"\s+", " ", entered_crop.strip().lower())
    a_norm = re.sub(r"\s+", " ", api_commodity.strip().lower())
    if e_norm == a_norm:
        return True

    e_tokens = set(_normalize_crop_tokens(entered_crop))
    a_tokens = set(_normalize_crop_tokens(api_commodity))
    if (e_tokens & set(a_norm.split())) or (
        e_tokens & a_tokens and any(len(t) >= 4 for t in (e_tokens & a_tokens))
    ):
        return True

    # Handle plural singular exact stem match (e.g. "Malt" != "Tomato")
    if e_tokens and a_tokens and (e_tokens & a_tokens):
        return True

    # Alias group check (e.g., "Tur dal" <-> "Arhar", "Pepper" <-> "Black pepper")
    if _crop_groups_for(entered_crop) & _crop_groups_for(api_commodity):
        return True

    return False


def _parse_api_records(records: list) -> List[dict]:
    parsed: List[dict] = []
    for rec in records:
        if not isinstance(rec, dict):
            continue
        commodity = rec.get("commodity") or rec.get("Commodity")
        modal = rec.get("modal_price") or rec.get("Modal_Price")
        market = rec.get("market") or rec.get("Market") or ""
        district = rec.get("district") or rec.get("District") or ""
        state = rec.get("state") or rec.get("State") or "Karnataka"
        if state and str(state).strip().lower() != "karnataka":
            continue
        if not commodity or not modal:
            continue
        try:
            modal_qtl = float(modal)
        except (TypeError, ValueError):
            continue
        if modal_qtl <= 0:
            continue
        parsed.append({
            "crop": str(commodity).strip(),
            "rate_per_kg": round(modal_qtl / 100.0, 2),
            "mandi": str(market).strip(),
            "district": str(district).strip(),
        })
    return parsed


def _fetch_live_karnataka_records(
    api_key: str,
    district: Optional[str] = None,
) -> List[dict]:
    """
    Fetch live Agmarknet rates using DATA_GOV_API_KEY (cached for 15 min).
    Returns [] cleanly on network failure or missing data.
    """
    cache_key = (district or "__all__").strip().lower()
    now = time.time()
    cached = _LIVE_RATE_CACHE.get(cache_key)
    if cached and (now - cached[0]) < _LIVE_CACHE_TTL_SECONDS:
        return cached[1]

    headers = {"User-Agent": "KisanRiderApp/1.0"}
    parsed: List[dict] = []

    try:
        with httpx.Client(timeout=6.0) as client:
            params: dict = {
                "api-key": api_key,
                "format": "json",
                "limit": 100 if district else 500,
                "filters[state.keyword]": "Karnataka",
            }
            if district and district.strip():
                params["filters[district]"] = district.strip()

            resp = client.get(_DATA_GOV_BASE_URL, params=params, headers=headers)
            resp.raise_for_status()
            payload = resp.json()
            records = payload.get("records") if isinstance(payload, dict) else []
            parsed = _parse_api_records(records or [])

            # If district-filtered call returned nothing, check state-wide cache/feed
            if not parsed and district and district.strip():
                state_cached = _LIVE_RATE_CACHE.get("__all__")
                if state_cached and (now - state_cached[0]) < _LIVE_CACHE_TTL_SECONDS:
                    all_parsed = state_cached[1]
                else:
                    resp2 = client.get(
                        _DATA_GOV_BASE_URL,
                        params={
                            "api-key": api_key,
                            "format": "json",
                            "limit": 500,
                            "filters[state.keyword]": "Karnataka",
                        },
                        headers=headers,
                    )
                    resp2.raise_for_status()
                    payload2 = resp2.json()
                    recs2 = payload2.get("records") if isinstance(payload2, dict) else []
                    all_parsed = _parse_api_records(recs2 or [])
                    _LIVE_RATE_CACHE["__all__"] = (now, all_parsed)

                d_lower = district.strip().lower()
                district_matches = [
                    r for r in all_parsed if r["district"].lower() == d_lower
                ]
                parsed = district_matches or all_parsed
    except Exception as exc:
        print(f"[payment-rate] Live Data.gov.in fetch failed ({type(exc).__name__}: {exc}); using fallback.")
        return []

    _LIVE_RATE_CACHE[cache_key] = (now, parsed)
    return parsed


def resolve_delivery_crop_rate_per_kg(
    crop_type: Optional[str],
    *,
    district: Optional[str] = None,
    mandi_name: Optional[str] = None,
) -> Tuple[float, str, Optional[str]]:
    """
    Resolve delivery-time crop price (Rs/kg) from Data.gov.in live mandi rates.

    Priority:
      1. Live Data.gov.in record matching both `mandi_name` and `crop_type`
      2. Live Data.gov.in record matching both `district` and `crop_type`
      3. Any Karnataka live Data.gov.in record matching `crop_type`
      4. Fallback Rs 50.0 / kg if API key is unset, API is unavailable, or crop is unlisted.
    """
    crop_clean = (crop_type or "").strip()
    if not crop_clean:
        return FALLBACK_RATE_PER_KG, "fallback", None

    api_key = (os.environ.get("DATA_GOV_API_KEY") or "").strip()
    if not api_key:
        return FALLBACK_RATE_PER_KG, "fallback", None

    records = _fetch_live_karnataka_records(api_key, district=district)
    if not records and district:
        records = _fetch_live_karnataka_records(api_key, district=None)

    if not records:
        return FALLBACK_RATE_PER_KG, "fallback", None

    crop_matches = [r for r in records if _crops_match(crop_clean, r["crop"])]

    # If filtered district records didn't list this crop, try all-Karnataka live records
    if not crop_matches and district:
        state_records = _fetch_live_karnataka_records(api_key, district=None)
        crop_matches = [r for r in state_records if _crops_match(crop_clean, r["crop"])]

    if not crop_matches:
        return FALLBACK_RATE_PER_KG, "fallback", None

    mandi_clean = (mandi_name or "").strip().lower()
    district_clean = (district or "").strip().lower()

    chosen = None
    if mandi_clean:
        for r in crop_matches:
            if mandi_clean in r["mandi"].lower() or r["mandi"].lower() in mandi_clean:
                chosen = r
                break

    if chosen is None and district_clean:
        for r in crop_matches:
            if r["district"].lower() == district_clean:
                chosen = r
                break

    if chosen is None:
        chosen = crop_matches[0]

    rate = float(chosen.get("rate_per_kg") or 0.0)
    if rate <= 0:
        return FALLBACK_RATE_PER_KG, "fallback", None

    return round(rate, 2), "mandi_api", chosen.get("mandi") or None


# ---------------------------------------------------------------------------
# QR Token & Payment / Auto-Split Operations
# ---------------------------------------------------------------------------

def build_qr_payload(target_id: UUID, amount: float) -> str:
    return f"KISANRIDER|{target_id}|{amount:.2f}"


def parse_qr_payload(qr_data: str) -> Tuple[UUID, Optional[float]]:
    raw = (qr_data or "").strip()
    if not raw:
        raise ValueError("Empty QR code.")

    parts = [p.strip() for p in raw.split("|") if p.strip()]
    parsed_amount: Optional[float] = None
    raw_id: Optional[str] = None

    if len(parts) == 1:
        raw_id = parts[0]
    elif len(parts) >= 3 and parts[0].upper() == "KISANRIDER":
        # Supports KISANRIDER|<uuid>|<amount> AND KISANRIDER|<KIND>|<uuid>|<amount>
        if len(parts) == 3:
            raw_id = parts[1]
            try:
                parsed_amount = float(parts[2])
            except ValueError:
                raise ValueError("Invalid payment amount in QR code.")
        else:
            raw_id = parts[2]
            try:
                parsed_amount = float(parts[3])
            except ValueError:
                raise ValueError("Invalid payment amount in QR code.")
    else:
        raise ValueError("Unrecognized QR code format. Expected a KisanRider payment QR.")

    try:
        target_uuid = UUID(raw_id)
    except ValueError as exc:
        raise ValueError("Invalid ID encoded in QR code.") from exc

    return target_uuid, parsed_amount


def _validate_numeric_pin(pin: str) -> str:
    cleaned = (pin or "").strip()
    if not cleaned:
        raise ValueError("Please enter a payment PIN.")
    if not cleaned.isdigit():
        raise ValueError("PIN must contain numeric digits only.")
    if len(cleaned) < 4 or len(cleaned) > 8:
        raise ValueError("PIN must be between 4 and 8 numeric digits.")
    return cleaned


def _settlement_item_dict(
    db: Session,
    settlement: models.Settlement,
    trip: Optional[models.Trip] = None,
) -> dict:
    if trip is None and settlement.trip_id:
        trip = (
            db.query(models.Trip)
            .options(joinedload(models.Trip.produce_request))
            .filter(models.Trip.id == settlement.trip_id)
            .first()
        )
    pr = trip.produce_request if trip else None
    farmer = (
        db.query(models.User).filter(models.User.id == settlement.farmer_id).first()
        if settlement.farmer_id
        else (pr.farmer if pr else None)
    )
    return {
        "settlement_id": settlement.id,
        "trip_id": settlement.trip_id,
        "farmer_id": settlement.farmer_id,
        "farmer_name": farmer.full_name if farmer else "Farmer",
        "crop_name": settlement.crop_name or (pr.crop_type if pr else "Produce"),
        "weight_kg": round(float(settlement.quantity_kg or (pr.weight_kg if pr else 0.0) or 0.0), 2),
        "rate_per_kg": round(float(settlement.rate_per_kg or FALLBACK_RATE_PER_KG), 2),
        "rate_source": settlement.rate_source or "fallback",
        "gross_amount": round(float(settlement.gross_amount or 0.0), 2),
        "rider_fare": round(float(settlement.rider_fare or settlement.total_payout or 0.0), 2),
        "platform_fee": round(float(settlement.platform_fee or 0.0), 2),
        "net_payout": round(float(settlement.net_payout or 0.0), 2),
        "status": settlement.status,
    }


def _build_settlement_qr_response(
    db: Session,
    s: models.Settlement,
    *,
    ensure_token: bool = True,
) -> dict:
    trip = (
        db.query(models.Trip)
        .options(
            joinedload(models.Trip.produce_request).joinedload(models.ProduceRequest.farmer),
            joinedload(models.Trip.rider),
        )
        .filter(models.Trip.id == s.trip_id)
        .first()
    )
    pr = trip.produce_request if trip else None
    rider = trip.rider if trip else (
        db.query(models.User).filter(models.User.id == s.rider_id).first() if s.rider_id else None
    )

    gross = round(float(s.gross_amount or 0.0), 2)
    rider_fare = round(float(s.rider_fare or s.total_payout or 0.0), 2)
    platform_fee = round(float(s.platform_fee or 0.0), 2)
    net_payout = round(float(s.net_payout or 0.0), 2)

    if gross <= 0 and (s.quantity_kg or 0) > 0:
        rate = float(s.rate_per_kg or FALLBACK_RATE_PER_KG)
        gross = round(float(s.quantity_kg) * rate, 2)
        platform_fee = round(gross * 0.02, 2)
        net_payout = round(gross - (rider_fare + platform_fee), 2)
        s.gross_amount = gross
        s.platform_fee = platform_fee
        s.net_payout = net_payout
        s.rate_per_kg = rate

    qr_data = s.qr_code_token or build_qr_payload(s.id, gross)
    if ensure_token and (s.qr_code_token != qr_data or s.qr_amount != gross):
        s.qr_code_token = qr_data
        s.qr_amount = gross
        db.commit()
        db.refresh(s)

    mandi_name = None
    if pr is not None:
        mandi_name = pr.dropoff_mandi_name or pr.dropoff_location or pr.dropoff_district

    item = _settlement_item_dict(db, s, trip=trip)
    return {
        "kind": "INDIVIDUAL",
        "target_id": s.id,
        "settlement_id": s.id,
        "pool_id": trip.pool_id if trip else None,
        "trip_id": s.trip_id,
        "qr_data": qr_data,
        "status": s.status,
        "total_amount": gross,
        "rider_fare": rider_fare,
        "platform_fee": platform_fee,
        "farmers_net_payout": net_payout,
        "rate_per_kg": round(float(s.rate_per_kg or FALLBACK_RATE_PER_KG), 2),
        "rate_source": s.rate_source or "fallback",
        "crop_name": s.crop_name or (pr.crop_type if pr else "Produce"),
        "total_weight_kg": round(float(s.quantity_kg or 0.0), 2),
        "mandi_name": mandi_name,
        "rider_name": rider.full_name if rider else "Rider",
        "payment_reference": s.payment_reference,
        "payment_method": s.payment_method,
        "paid_at": s.paid_at,
        "items": [item],
    }


def _collect_pool_settlements(db: Session, pool_id: UUID):
    from pools import models as pool_models

    pool = db.query(pool_models.Pool).filter(pool_models.Pool.id == pool_id).first()
    if pool is None:
        raise ValueError("Pool not found")

    trips = (
        db.query(models.Trip)
        .options(
            joinedload(models.Trip.produce_request).joinedload(models.ProduceRequest.farmer),
            joinedload(models.Trip.rider),
            joinedload(models.Trip.settlement),
        )
        .filter(
            models.Trip.pool_id == pool_id,
            models.Trip.status.notin_(("CANCELLED", "MISSED")),
        )
        .order_by(models.Trip.created_at.asc())
        .all()
    )
    if not trips:
        raise ValueError("No active trips found for this pool")

    if any(t.status not in ("DELIVERED", "COMPLETED") for t in trips):
        raise ValueError("Pool must be marked as delivered before generating payment QR.")

    # Auto-heal if any delivered trip in pool lacks a Settlement
    settlements: List[models.Settlement] = []
    missing_any = False
    total_w = sum(
        float(t.produce_request.weight_kg or 0.0)
        for t in trips
        if t.produce_request is not None
    )
    for t in trips:
        if t.settlement is None:
            from crud import _ensure_settlement_for_trip
            created = _ensure_settlement_for_trip(
                db, t, t.produce_request, None, fare_share_weight_total=total_w or None
            )
            if created is not None:
                missing_any = True
                db.flush()
                settlements.append(created)
        else:
            settlements.append(t.settlement)

    if missing_any:
        db.commit()
        for s in settlements:
            db.refresh(s)

    if not settlements:
        raise ValueError("No settlements found for this pool.")

    return pool, trips, settlements


def _build_pool_qr_response(
    db: Session,
    pool_id: UUID,
    *,
    ensure_token: bool = True,
) -> dict:
    pool, trips, settlements = _collect_pool_settlements(db, pool_id)

    total_amount = round(sum(float(s.gross_amount or 0.0) for s in settlements), 2)
    rider_fare = round(sum(float(s.rider_fare or s.total_payout or 0.0) for s in settlements), 2)
    platform_fee = round(sum(float(s.platform_fee or 0.0) for s in settlements), 2)
    farmers_net_payout = round(sum(float(s.net_payout or 0.0) for s in settlements), 2)
    total_weight_kg = round(sum(float(s.quantity_kg or 0.0) for s in settlements), 2)

    all_paid = all(s.status == "PAID" for s in settlements)
    status = "PAID" if all_paid else "PENDING"

    qr_data = build_qr_payload(pool.id, total_amount)
    if ensure_token:
        dirty = False
        for s in settlements:
            if s.qr_code_token != qr_data or s.qr_amount != total_amount:
                s.qr_code_token = qr_data
                s.qr_amount = total_amount
                dirty = True
        if dirty:
            db.commit()

    trip_by_id = {t.id: t for t in trips}
    items = [
        _settlement_item_dict(db, s, trip=trip_by_id.get(s.trip_id))
        for s in settlements
    ]

    rider = next((t.rider for t in trips if t.rider is not None), None)
    paid_refs = [s.payment_reference for s in settlements if s.payment_reference]
    paid_ats = [s.paid_at for s in settlements if s.paid_at]
    first_s = settlements[0]

    return {
        "kind": "POOL",
        "target_id": pool.id,
        "settlement_id": None,
        "pool_id": pool.id,
        "trip_id": None,
        "qr_data": qr_data,
        "status": status,
        "total_amount": total_amount,
        "rider_fare": rider_fare,
        "platform_fee": platform_fee,
        "farmers_net_payout": farmers_net_payout,
        "rate_per_kg": round(float(first_s.rate_per_kg or FALLBACK_RATE_PER_KG), 2),
        "rate_source": first_s.rate_source or "fallback",
        "crop_name": pool.crop_type,
        "total_weight_kg": total_weight_kg,
        "mandi_name": pool.dropoff_mandi_name or pool.dropoff_district,
        "rider_name": rider.full_name if rider else "Rider",
        "payment_reference": paid_refs[0] if paid_refs else None,
        "payment_method": first_s.payment_method,
        "paid_at": max(paid_ats) if paid_ats else None,
        "items": items,
    }


def _assert_user_can_access_settlement(s: models.Settlement, user: Optional[models.User]) -> None:
    if user is None or user.role == "ADMIN":
        return
    if user.id not in (s.rider_id, s.farmer_id):
        raise PermissionError("You are not authorized to access this settlement.")


def generate_settlement_qr(
    db: Session,
    settlement_id: UUID,
    actor_user: Optional[models.User] = None,
) -> dict:
    s = db.query(models.Settlement).filter(models.Settlement.id == settlement_id).first()
    if s is None:
        raise LookupError("Settlement not found.")
    _assert_user_can_access_settlement(s, actor_user)
    return _build_settlement_qr_response(db, s, ensure_token=True)


def generate_trip_qr(
    db: Session,
    trip_id: UUID,
    actor_user: Optional[models.User] = None,
) -> dict:
    trip = (
        db.query(models.Trip)
        .options(joinedload(models.Trip.produce_request))
        .filter(models.Trip.id == trip_id)
        .first()
    )
    if trip is None:
        raise LookupError("Trip not found.")
    if actor_user is not None and actor_user.role != "ADMIN":
        farmer_id = trip.produce_request.farmer_id if trip.produce_request else None
        if actor_user.id not in (trip.rider_id, farmer_id):
            raise PermissionError("You are not authorized for this trip.")

    if trip.status not in ("DELIVERED", "COMPLETED"):
        raise ValueError("Trip must be marked as delivered before generating payment QR.")

    s = db.query(models.Settlement).filter(models.Settlement.trip_id == trip.id).first()
    if s is None:
        from crud import _ensure_settlement_for_trip
        s = _ensure_settlement_for_trip(db, trip, trip.produce_request, None)
        if s is None:
            raise LookupError("Settlement not found for this trip.")
        db.commit()
        db.refresh(s)

    return _build_settlement_qr_response(db, s, ensure_token=True)


def generate_pool_qr(
    db: Session,
    pool_id: UUID,
    actor_user: Optional[models.User] = None,
) -> dict:
    _, trips, _ = _collect_pool_settlements(db, pool_id)
    if actor_user is not None and actor_user.role != "ADMIN":
        allowed_ids = {t.rider_id for t in trips} | {
            t.produce_request.farmer_id
            for t in trips
            if t.produce_request is not None
        }
        if actor_user.id not in allowed_ids:
            raise PermissionError("You are not authorized for this pool.")

    return _build_pool_qr_response(db, pool_id, ensure_token=True)


def get_settlement_payment_status(
    db: Session,
    settlement_id: UUID,
    actor_user: Optional[models.User] = None,
) -> dict:
    s = db.query(models.Settlement).filter(models.Settlement.id == settlement_id).first()
    if s is None:
        raise LookupError("Settlement not found.")
    _assert_user_can_access_settlement(s, actor_user)
    return _build_settlement_qr_response(db, s, ensure_token=False)


def get_trip_payment_status(
    db: Session,
    trip_id: UUID,
    actor_user: Optional[models.User] = None,
) -> dict:
    trip = db.query(models.Trip).filter(models.Trip.id == trip_id).first()
    if trip is None:
        raise LookupError("Trip not found.")
    s = db.query(models.Settlement).filter(models.Settlement.trip_id == trip_id).first()
    if s is None:
        raise LookupError("Settlement not yet created for this trip.")
    _assert_user_can_access_settlement(s, actor_user)
    return _build_settlement_qr_response(db, s, ensure_token=False)


def get_pool_payment_status(
    db: Session,
    pool_id: UUID,
    actor_user: Optional[models.User] = None,
) -> dict:
    _, trips, _ = _collect_pool_settlements(db, pool_id)
    if actor_user is not None and actor_user.role != "ADMIN":
        allowed_ids = {t.rider_id for t in trips} | {
            t.produce_request.farmer_id
            for t in trips
            if t.produce_request is not None
        }
        if actor_user.id not in allowed_ids:
            raise PermissionError("You are not authorized for this pool.")
    return _build_pool_qr_response(db, pool_id, ensure_token=False)


def inspect_qr_payment(db: Session, qr_data: str) -> dict:
    from pools import models as pool_models

    target_id, encoded_amount = parse_qr_payload(qr_data)

    # 1. Check Pool ID first (single QR for whole pool)
    pool = db.query(pool_models.Pool).filter(pool_models.Pool.id == target_id).first()
    if pool is not None:
        info = _build_pool_qr_response(db, pool.id, ensure_token=False)
        if encoded_amount is not None and abs(encoded_amount - info["total_amount"]) > 1.0:
            raise ValueError("QR amount mismatch with current pool total.")
        return info

    # 2. Check Settlement ID (single QR for individual delivery)
    s = db.query(models.Settlement).filter(models.Settlement.id == target_id).first()
    if s is not None:
        info = _build_settlement_qr_response(db, s, ensure_token=False)
        if encoded_amount is not None and abs(encoded_amount - info["total_amount"]) > 1.0:
            raise ValueError("QR amount mismatch with settlement total.")
        return info

    raise LookupError("No matching payment found for this QR code.")


def pay_settlement(
    db: Session,
    settlement_id: UUID,
    pin: str,
    qr_data: Optional[str] = None,
) -> dict:
    _validate_numeric_pin(pin)

    s = (
        db.query(models.Settlement)
        .filter(models.Settlement.id == settlement_id)
        .with_for_update()
        .first()
    )
    if s is None:
        raise LookupError("Settlement not found.")

    if qr_data:
        parsed_id, parsed_amount = parse_qr_payload(qr_data)
        if parsed_id != s.id:
            raise ValueError("QR code does not match this settlement.")
        if parsed_amount is not None and s.gross_amount is not None:
            if abs(parsed_amount - float(s.gross_amount)) > 1.0:
                raise ValueError("QR amount does not match settlement total.")

    if s.status == "PAID":
        raise ValueError("This settlement has already been paid.")

    now_utc = datetime.now(timezone.utc)
    ref = f"QR-{uuid.uuid4().hex[:10].upper()}"
    s.status = "PAID"
    s.payment_reference = ref
    s.payment_method = "QR_SCAN"
    s.paid_at = now_utc
    if not s.qr_code_token and s.gross_amount is not None:
        s.qr_code_token = build_qr_payload(s.id, float(s.gross_amount))
        s.qr_amount = float(s.gross_amount)

    db.commit()
    db.refresh(s)
    info = _build_settlement_qr_response(db, s, ensure_token=False)
    return {
        "success": True,
        "message": "Payment successful! Funds split to Rider, Platform, and Farmer.",
        **info,
    }


def pay_pool(
    db: Session,
    pool_id: UUID,
    pin: str,
    qr_data: Optional[str] = None,
) -> dict:
    _validate_numeric_pin(pin)

    _, _, settlements = _collect_pool_settlements(db, pool_id)
    settlement_ids = [s.id for s in settlements]
    locked = (
        db.query(models.Settlement)
        .filter(models.Settlement.id.in_(settlement_ids))
        .with_for_update()
        .all()
    )

    total_expected = round(sum(float(s.gross_amount or 0.0) for s in locked), 2)
    if qr_data:
        parsed_id, parsed_amount = parse_qr_payload(qr_data)
        if parsed_id != pool_id:
            raise ValueError("QR code does not match this pool.")
        if parsed_amount is not None and abs(parsed_amount - total_expected) > 1.0:
            raise ValueError("QR amount does not match pool total.")

    if all(s.status == "PAID" for s in locked):
        raise ValueError("This pool payment has already been completed.")

    now_utc = datetime.now(timezone.utc)
    ref = f"QR-{uuid.uuid4().hex[:10].upper()}"
    qr_token = build_qr_payload(pool_id, total_expected)
    for s in locked:
        if s.status != "PAID":
            s.status = "PAID"
            s.payment_reference = ref
            s.payment_method = "QR_SCAN"
            s.paid_at = now_utc
            s.qr_code_token = qr_token
            s.qr_amount = total_expected

    db.commit()
    info = _build_pool_qr_response(db, pool_id, ensure_token=False)
    return {
        "success": True,
        "message": "Pool payment successful! Auto-split across Rider, Platform, and all Farmers.",
        **info,
    }


def pay_via_qr(db: Session, qr_data: str, pin: str) -> dict:
    from pools import models as pool_models

    target_id, _ = parse_qr_payload(qr_data)
    pool = db.query(pool_models.Pool).filter(pool_models.Pool.id == target_id).first()
    if pool is not None:
        return pay_pool(db, pool.id, pin=pin, qr_data=qr_data)

    s = db.query(models.Settlement).filter(models.Settlement.id == target_id).first()
    if s is not None:
        return pay_settlement(db, s.id, pin=pin, qr_data=qr_data)

    raise LookupError("No matching payment found for this QR code.")
