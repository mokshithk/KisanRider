"""
CRUD layer for KisanRider.

Spatial notes:
- pickup_location is stored as geometry(POINT, 4326) — planar SRID, good for
  storage/indexing but NOT for distance math (degrees, not meters).
- For distance filtering/sorting we cast to `geography` inline in the query,
  which makes PostGIS compute true great-circle distances in meters over the
  WGS84 spheroid. This is the standard "store as geometry, query as
  geography" pattern and lets a GiST index on the geometry column still be
  used efficiently by ST_DWithin.
"""

import random
from typing import List, Optional
from uuid import UUID

from geoalchemy2 import Geography, Geometry
from geoalchemy2.elements import WKTElement
from geoalchemy2.functions import ST_DWithin, ST_Distance, ST_MakePoint, ST_SetSRID, ST_X, ST_Y
from geoalchemy2.shape import to_shape
from sqlalchemy import cast, func
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, joinedload

from datetime import datetime

import models
import schemas


# ---------------------------------------------------------------------------
# Settlement economics — single place to tune the money math
# ---------------------------------------------------------------------------

# Platform's cut of the gross mandi sale, as a fraction.
_PLATFORM_FEE_RATE = 0.02  # 2%

# Placeholder mandi rate when the caller doesn't supply one. Real rate should
# come from the /mandi-rates/ feed or a user-supplied value.
_DEFAULT_RATE_PER_KG = 40.0  # ₹ per kg

# Placeholder trip distance for the auto-created settlement when the caller
# doesn't supply one. Trips don't currently record distance travelled, so
# this is the fallback until GPS-trail tracking exists.
_DEFAULT_DISTANCE_KM = 10.0


# ---------------------------------------------------------------------------
# User CRUD
# ---------------------------------------------------------------------------

def get_user_by_phone(db: Session, phone: str) -> Optional[models.User]:
    return db.query(models.User).filter(models.User.phone == phone).first()


def get_user_by_id(db: Session, user_id: UUID) -> Optional[models.User]:
    return db.query(models.User).filter(models.User.id == user_id).first()


def create_user(db: Session, user_schema: schemas.UserCreate) -> models.User:
    db_user = models.User(
        phone=user_schema.phone,
        role=user_schema.role,
        full_name=user_schema.full_name,
    )
    try:
        db.add(db_user)
        db.commit()
        db.refresh(db_user)
        return db_user
    except SQLAlchemyError:
        db.rollback()
        raise


# ---------------------------------------------------------------------------
# ProduceRequest CRUD
# ---------------------------------------------------------------------------

def _to_response(pr: models.ProduceRequest) -> schemas.ProduceRequestResponse:
    """
    Convert an ORM row (with a WKBElement geometry) into the API schema.

    Used for READ paths (get-by-id, nearby search) where we have no other
    source for latitude/longitude and must decode the stored geometry.
    Wrapped so a malformed/NULL geometry surfaces as a ValueError, which
    main.py maps to a clean 400 instead of an unhandled 500.
    """
    try:
        point = to_shape(pr.pickup_location)  # shapely Point; .x = lng, .y = lat
    except Exception as e:
        raise ValueError(f"Could not decode stored geometry for produce request {pr.id}: {e}") from e

    return schemas.ProduceRequestResponse(
        id=pr.id,
        farmer_id=pr.farmer_id,
        crop_type=pr.crop_type,
        crate_count=pr.crate_count,
        weight_kg=float(pr.weight_kg),
        latitude=point.y,
        longitude=point.x,
        dropoff_location=pr.dropoff_location,
        dropoff_lat=pr.dropoff_lat,
        dropoff_lng=pr.dropoff_lng,
        status=pr.status,
        created_at=pr.created_at,
    )


def create_produce_request(
    db: Session,
    request_schema: schemas.ProduceRequestCreate,
    farmer_id: UUID,
) -> schemas.ProduceRequestResponse:
    """
    Insert a produce request.

    Deliberately does NOT call `_to_response()` / `to_shape()` on the
    freshly-inserted row: we already have validated latitude/longitude on
    `request_schema`, and re-decoding the WKB the DB just handed back on
    `db.refresh()` is unnecessary round-tripping that's a common source of
    silent 500s (hex-WKB vs WKBElement edge cases). The write path trusts
    the input it just persisted; only read paths decode geometry.

    Generates the 4-digit pickup OTP here (not in main.py) because this is
    where the DB insert happens — putting it in main.py would only move the
    same logic and require a new parameter on this function's signature.
    """
    try:
        point_wkt = WKTElement(
            f"POINT({request_schema.longitude} {request_schema.latitude})",
            srid=4326,
        )
    except Exception as e:
        raise ValueError(f"Invalid coordinates ({request_schema.latitude}, {request_schema.longitude}): {e}") from e

    # Handoff code: the farmer reads this to the rider at pickup. Generated
    # once at creation so it's stable across the request's lifecycle and
    # visible in the farmer's own /produce-requests/farmer/me feed.
    pickup_otp = f"{random.randint(1000, 9999)}"

    db_request = models.ProduceRequest(
        farmer_id=farmer_id,
        crop_type=request_schema.crop_type,
        crate_count=request_schema.crate_count,
        weight_kg=request_schema.weight_kg,
        pickup_location=point_wkt,
        dropoff_location=request_schema.dropoff_location,
        dropoff_lat=request_schema.dropoff_lat,
        dropoff_lng=request_schema.dropoff_lng,
        pickup_otp=pickup_otp,
        status="PENDING",
    )

    try:
        db.add(db_request)
        db.commit()
        db.refresh(db_request)
    except SQLAlchemyError:
        db.rollback()
        raise

    return schemas.ProduceRequestResponse(
        id=db_request.id,
        farmer_id=db_request.farmer_id,
        crop_type=db_request.crop_type,
        crate_count=db_request.crate_count,
        weight_kg=float(db_request.weight_kg),
        latitude=request_schema.latitude,
        longitude=request_schema.longitude,
        dropoff_location=db_request.dropoff_location,
        dropoff_lat=db_request.dropoff_lat,
        dropoff_lng=db_request.dropoff_lng,
        status=db_request.status,
        created_at=db_request.created_at,
    )


def get_produce_request_by_id(db: Session, request_id: UUID) -> Optional[schemas.ProduceRequestResponse]:
    pr = db.query(models.ProduceRequest).filter(models.ProduceRequest.id == request_id).first()
    return _to_response(pr) if pr else None


def _to_farmer_response(pr: models.ProduceRequest) -> schemas.FarmerProduceRequestResponse:
    """
    Extend `_to_response()` with the request's trip (if any) and that
    trip's rider, for the farmer tracking feed. Reuses `_to_response()`
    rather than re-decoding the geometry, so there's one place that turns
    a WKBElement into lat/lng.
    """
    base = _to_response(pr)

    trip_summary = None
    if pr.trip:
        rider_summary = (
            schemas.RiderSummary(
                id=pr.trip.rider.id,
                full_name=pr.trip.rider.full_name,
                phone=pr.trip.rider.phone,
            )
            if pr.trip.rider
            else None
        )
        trip_summary = schemas.TripSummary(
            id=pr.trip.id,
            status=pr.trip.status,
            created_at=pr.trip.created_at,
            completed_at=pr.trip.completed_at,
            rider=rider_summary,
        )

    return schemas.FarmerProduceRequestResponse(
        **base.model_dump(),
        trip=trip_summary,
        pickup_otp=pr.pickup_otp,
    )


def get_produce_requests_for_farmer(
    db: Session, farmer_id: UUID
) -> List[schemas.FarmerProduceRequestResponse]:
    """
    All produce requests a farmer has created, newest first, each carrying
    its trip (rider + status) if one has been accepted.

    `joinedload` on `ProduceRequest.trip` and `Trip.rider` fetches both in
    the same query (two LEFT JOINs) rather than issuing a follow-up query
    per row (the classic N+1) — `trip` is nullable so this has to be a LEFT
    JOIN, which `joinedload` handles correctly for a to-one relationship.
    """
    requests = (
        db.query(models.ProduceRequest)
        .options(joinedload(models.ProduceRequest.trip).joinedload(models.Trip.rider))
        .filter(models.ProduceRequest.farmer_id == farmer_id)
        .order_by(models.ProduceRequest.created_at.desc())
        .all()
    )
    return [_to_farmer_response(pr) for pr in requests]


def get_farmer_produce_requests(
    db: Session, farmer_id: UUID
) -> List[schemas.ProduceRequestResponse]:
    """
    All produce requests created by `farmer_id`, newest first.

    Flat list of ProduceRequestResponse (no trip/rider nesting) — the MVP
    view used by GET /trips/me. Reuses `_to_response()` so the geometry ->
    lat/lng decoding stays in one place.
    """
    rows = (
        db.query(models.ProduceRequest)
        .filter(models.ProduceRequest.farmer_id == farmer_id)
        .order_by(models.ProduceRequest.created_at.desc())
        .all()
    )
    return [_to_response(pr) for pr in rows]


def get_nearby_produce_requests(
    db: Session,
    lat: float,
    lng: float,
    radius_km: float,
    status_filter: Optional[str] = "PENDING",
    limit: int = 50,
) -> List[schemas.NearbyProduceRequestResponse]:
    """
    Find produce requests within `radius_km` of (lat, lng), nearest first.

    This selects plain scalar columns (id, crop_type, ..., latitude,
    longitude, distance_km) instead of full ProduceRequest ORM entities.
    latitude/longitude are computed by PostGIS itself via ST_Y/ST_X, so the
    driver never hands a WKBElement back to Python at all — the class of
    bug that caused the previous 500 (Pydantic trying to serialize a raw
    binary geometry object) is structurally impossible here.

    Distance math uses ::geography casts so ST_DWithin/ST_Distance operate
    in real meters over the WGS84 spheroid, not raw lat/lng degrees; ST_Y/
    ST_X use plain ::geometry, matching how the column is actually stored.

    NOTE: pickup_otp is deliberately NOT selected here — the rider-facing
    nearby feed must not expose the farmer's handoff code.
    """
    pr = models.ProduceRequest

    query_point = ST_SetSRID(ST_MakePoint(lng, lat), 4326)
    query_point_geog = cast(query_point, Geography)
    stored_geog = cast(pr.pickup_location, Geography)
    stored_geom = cast(pr.pickup_location, Geometry)

    distance_km = (ST_Distance(stored_geog, query_point_geog) / 1000.0).label("distance_km")
    latitude_col = ST_Y(stored_geom).label("latitude")
    longitude_col = ST_X(stored_geom).label("longitude")

    query = (
        db.query(
            pr.id,
            pr.farmer_id,
            pr.crop_type,
            pr.crate_count,
            pr.weight_kg,
            pr.status,
            pr.created_at,
            pr.dropoff_location,
            pr.dropoff_lat,
            pr.dropoff_lng,
            latitude_col,
            longitude_col,
            distance_km,
        )
        .filter(ST_DWithin(stored_geog, query_point_geog, radius_km * 1000))
    )

    if status_filter:
        query = query.filter(pr.status == status_filter)

    query = query.order_by(distance_km.asc()).limit(limit)

    try:
        rows = query.all()
    except SQLAlchemyError:
        raise

    return [
        schemas.NearbyProduceRequestResponse(
            id=row.id,
            farmer_id=row.farmer_id,
            crop_type=row.crop_type,
            crate_count=row.crate_count,
            weight_kg=float(row.weight_kg),
            latitude=row.latitude,
            longitude=row.longitude,
            dropoff_location=row.dropoff_location,
            dropoff_lat=row.dropoff_lat,
            dropoff_lng=row.dropoff_lng,
            status=row.status,
            created_at=row.created_at,
            distance_km=round(row.distance_km, 3),
        )
        for row in rows
    ]


def verify_pickup_otp(
    db: Session, request_id: UUID, otp: str
) -> Optional[models.ProduceRequest]:
    """
    Pickup-handoff confirmation. Compares the submitted OTP against the one
    stored on the request and, on a match, flips the request's status to
    PICKED_UP.

    Returns None if the request doesn't exist (main.py -> 404). Raises
    ValueError (main.py -> 400) for domain errors: request is in a terminal
    state, isn't ACCEPTED yet, has no OTP on file, or the submitted code
    doesn't match.

    Only ACCEPTED requests can be verified — PENDING has no rider yet, and
    PICKED_UP/COMPLETED/CANCELLED have already moved past the handoff. That
    guard is what makes this endpoint idempotent-safe: a second submit with
    the same OTP hits the "not ACCEPTED" branch instead of silently
    transitioning a delivered request back to PICKED_UP.

    Row-locked with `with_for_update()` so two concurrent verify calls for
    the same request can't both flip the status.
    """
    pr = (
        db.query(models.ProduceRequest)
        .filter(models.ProduceRequest.id == request_id)
        .with_for_update()
        .first()
    )
    if pr is None:
        return None

    if pr.status in ("COMPLETED", "CANCELLED"):
        raise ValueError(
            f"Request is in a terminal state ({pr.status}) and cannot be picked up"
        )

    if pr.status != "ACCEPTED":
        raise ValueError(
            f"Request must be ACCEPTED before OTP verification (current status: {pr.status})"
        )

    # `pr.pickup_otp` is None for rows created before the column existed —
    # those can never be verified, which is the safe behavior (fail closed).
    if not pr.pickup_otp or pr.pickup_otp != otp.strip():
        raise ValueError("Invalid OTP")

    pr.status = "PICKED_UP"
    try:
        db.commit()
        db.refresh(pr)
        return pr
    except SQLAlchemyError:
        db.rollback()
        raise


# ---------------------------------------------------------------------------
# Trip CRUD
# ---------------------------------------------------------------------------

def get_trip_by_id(db: Session, trip_id: UUID) -> Optional[models.Trip]:
    """Plain lookup, used by main.py to check trip ownership before allowing a status update."""
    return db.query(models.Trip).filter(models.Trip.id == trip_id).first()


def accept_produce_request(db: Session, request_id: UUID, rider_id: UUID) -> models.Trip:
    """
    A rider accepts a PENDING produce request, creating a Trip and flipping
    the request's status to 'ACCEPTED'.

    Note on layering: like the rest of this module, domain-level failures
    (not found / already taken) are raised as ValueError rather than
    HTTPException — crud.py stays framework-agnostic and main.py is
    responsible for translating these into HTTP responses (it already does
    this for every other endpoint via `except (SQLAlchemyError, ValueError)`).

    `with_for_update()` row-locks the ProduceRequest row for the duration of
    this transaction, so two riders hitting this endpoint for the same
    request concurrently can't both succeed — the second one blocks until
    the first commits, then re-reads status as 'ACCEPTED' and is correctly
    rejected instead of racing past the check.
    """
    try:
        pr = (
            db.query(models.ProduceRequest)
            .filter(models.ProduceRequest.id == request_id)
            .with_for_update()
            .first()
        )

        if not pr or pr.status != "PENDING":
            raise ValueError("Produce request unavailable or already accepted")

        pr.status = "ACCEPTED"

        db_trip = models.Trip(
            produce_request_id=request_id,
            rider_id=rider_id,
            status="ACCEPTED",
        )
        db.add(db_trip)
        db.commit()
        db.refresh(db_trip)
        return db_trip
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise


def update_trip_status(
    db: Session,
    trip_id: UUID,
    status: str,
    distance_km: Optional[float] = None,
) -> Optional[models.Trip]:
    """
    Transition a Trip to a new status ('PICKED_UP', 'DELIVERED', or
    'CANCELLED' — enforced upstream by schemas.TripStatusUpdate).

    Returns None if the trip doesn't exist, so main.py can raise a 404 the
    same way it already does for get_produce_request_by_id. Everything else
    (terminal-state guard) is a domain error raised as ValueError, which
    main.py maps to 400 — same layering as accept_produce_request.

    On transition to 'DELIVERED': stamps `completed_at`, marks the linked
    ProduceRequest as 'COMPLETED', AND auto-creates a Settlement row for the
    trip — all in one transaction. The settlement carries both the rider's
    fare breakdown (base + distance + weight surcharge) and the farmer's
    payout breakdown (gross mandi sale − rider fare − platform fee), computed
    from the ProduceRequest's weight and the caller-supplied `distance_km`
    (falling back to a placeholder if omitted).

    On 'CANCELLED': also stamps `completed_at` (CANCELLED is terminal) but
    leaves the ProduceRequest status untouched and creates no settlement —
    reopening it for another rider is a separate concern this endpoint
    doesn't own.

    Both the Trip and its ProduceRequest are row-locked for the duration of
    the transaction, consistent with accept_produce_request, so a status
    update can't race another writer touching the same rows. If any part of
    the delivery path fails — the ProduceRequest update, the settlement
    insert, anything — the single `db.rollback()` reverts everything, so a
    trip is never left marked DELIVERED without its matching settlement.
    """
    try:
        trip = (
            db.query(models.Trip)
            .filter(models.Trip.id == trip_id)
            .with_for_update()
            .first()
        )

        if not trip:
            return None

        if trip.status in ("DELIVERED", "CANCELLED"):
            raise ValueError(f"Trip is already in a terminal state ({trip.status}) and cannot be updated")

        pr: Optional[models.ProduceRequest] = None

        if status == "DELIVERED":
            trip.completed_at = datetime.utcnow()

            pr = (
                db.query(models.ProduceRequest)
                .filter(models.ProduceRequest.id == trip.produce_request_id)
                .with_for_update()
                .first()
            )
            if pr:
                pr.status = "COMPLETED"
        elif status == "CANCELLED":
            trip.completed_at = datetime.utcnow()

        trip.status = status

        # Auto-create the settlement in the same transaction. The helper
        # is idempotent (it checks for an existing row first), so a
        # duplicate PATCH that somehow slips past the terminal-state guard
        # won't create two settlements for the same trip.
        if status == "DELIVERED":
            _ensure_settlement_for_trip(db, trip, pr, distance_km)

        db.commit()
        db.refresh(trip)
        return trip
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise


def get_active_trips_for_rider(db: Session, rider_id: UUID) -> List[models.Trip]:
    """
    All of the rider's active trips (status ACCEPTED or PICKED_UP), newest
    first, each with its ProduceRequest eager-loaded.

    A rider can legitimately hold more than one active trip (accepting a
    second produce request while the first is still in progress), so this
    returns every match rather than `.first()`.
    """
    return (
        db.query(models.Trip)
        .options(joinedload(models.Trip.produce_request))
        .filter(
            models.Trip.rider_id == rider_id,
            models.Trip.status.in_(("ACCEPTED", "PICKED_UP")),
        )
        .order_by(models.Trip.created_at.desc())
        .all()
    )


# ---------------------------------------------------------------------------
# CrateScan CRUD
# ---------------------------------------------------------------------------

def create_crate_scan(
    db: Session, scan_data: schemas.CrateScanCreate, user_id: UUID
) -> Optional[models.CrateScan]:
    """
    Record a crate QR-code scan (PICKUP or DELIVERY) against a trip.

    Returns None if `trip_id` doesn't exist, so main.py can raise the 404 —
    same layering convention as get_produce_request_by_id/update_trip_status:
    crud.py signals "not found" via None and domain errors via ValueError,
    and main.py owns the HTTP status mapping.
    """
    trip_exists = db.query(models.Trip.id).filter(models.Trip.id == scan_data.trip_id).first()
    if not trip_exists:
        return None

    db_scan = models.CrateScan(
        trip_id=scan_data.trip_id,
        scanned_by_id=user_id,
        scan_type=scan_data.scan_type,
        qr_code=scan_data.qr_code,
    )

    try:
        db.add(db_scan)
        db.commit()
        db.refresh(db_scan)
        return db_scan
    except SQLAlchemyError:
        db.rollback()
        raise


# ---------------------------------------------------------------------------
# Settlement CRUD
# ---------------------------------------------------------------------------

def _compute_settlement_values(
    weight_kg: float,
    distance_km: float,
    rate_per_kg: float,
) -> dict:
    """
    Single source of truth for the fare/payout arithmetic.

    Both `create_settlement` (the manual / admin endpoint) and
    `_ensure_settlement_for_trip` (the auto-creation path when a trip is
    marked DELIVERED) call this, so the two never drift apart.

    Returns a dict of every numeric field the Settlement row needs. Kept
    as a plain dict rather than a NamedTuple to avoid a new module-level
    type for what's fundamentally an internal helper.
    """
    # ----- Rider fare breakdown -------------------------------------------
    base_fare = 50.0
    distance_fare = distance_km * 15.0
    weight_surcharge = max(0.0, weight_kg - 50.0) * 2.0
    rider_fare = base_fare + distance_fare + weight_surcharge

    # ----- Farmer payout breakdown ----------------------------------------
    gross_amount = weight_kg * rate_per_kg
    platform_fee = gross_amount * _PLATFORM_FEE_RATE
    net_payout = gross_amount - (rider_fare + platform_fee)

    return {
        "base_fare": base_fare,
        "distance_fare": distance_fare,
        "weight_surcharge": weight_surcharge,
        "rider_fare": rider_fare,
        "gross_amount": gross_amount,
        "platform_fee": platform_fee,
        "net_payout": net_payout,
    }


def _ensure_settlement_for_trip(
    db: Session,
    trip: models.Trip,
    pr: Optional[models.ProduceRequest],
    distance_km: Optional[float],
) -> Optional[models.Settlement]:
    """
    Create a Settlement row for `trip` if one doesn't already exist.

    Called from `update_trip_status` on the DELIVERED transition, so the
    settlement is staged with `db.add()` and committed by the caller's
    single `db.commit()` — i.e. the trip status change and the settlement
    insert land in the same transaction and either both succeed or both
    roll back.

    Idempotency: if a settlement already exists for this trip_id, this is a
    no-op. That protects against duplicate PATCHes slipping through (though
    the terminal-state guard in update_trip_status already blocks the common
    case) and matches the DB-level unique constraint on Settlement.trip_id.

    `pr` may be None in pathological cases (it shouldn't be — the FK
    cascades deletes — but defensive code wins). When None, the settlement
    is created with farmer_id / crop_name / quantity_kg all null; the row
    still records the rider's side of the transaction.

    `distance_km` falls back to `_DEFAULT_DISTANCE_KM` when the caller
    didn't supply one. Trips don't yet track real distance travelled, so
    this is the placeholder until that's wired up.
    """
    existing = (
        db.query(models.Settlement.id)
        .filter(models.Settlement.trip_id == trip.id)
        .first()
    )
    if existing:
        return None

    weight_kg = (
        float(pr.weight_kg)
        if pr is not None and pr.weight_kg is not None
        else 0.0
    )
    values = _compute_settlement_values(
        weight_kg,
        distance_km if distance_km is not None else _DEFAULT_DISTANCE_KM,
        _DEFAULT_RATE_PER_KG,
    )

    db_settlement = models.Settlement(
        trip_id=trip.id,
        rider_id=trip.rider_id,
        farmer_id=pr.farmer_id if pr is not None else None,
        crop_name=pr.crop_type if pr is not None else None,
        quantity_kg=weight_kg,
        # Rider side — total_payout == rider_fare by design (see models.py).
        base_fare=values["base_fare"],
        distance_fare=values["distance_fare"],
        weight_surcharge=values["weight_surcharge"],
        total_payout=values["rider_fare"],
        # Farmer side.
        gross_amount=values["gross_amount"],
        rider_fare=values["rider_fare"],
        platform_fee=values["platform_fee"],
        net_payout=values["net_payout"],
        # Money hasn't moved yet — an admin / payout worker flips this to
        # "PAID" once the transfer is confirmed. Same convention as the
        # manual endpoint.
        status="PENDING",
    )
    db.add(db_settlement)
    return db_settlement


def create_settlement(
    db: Session, settlement_in: schemas.SettlementCreate
) -> Optional[models.Settlement]:
    """
    Manual / admin creation of a settlement for a DELIVERED trip.

    In the normal rider flow this is redundant — PATCH /trips/{id}/status
    with {"status": "DELIVERED"} now auto-creates the settlement. This
    endpoint remains useful for retries, backfills, or a scenario where
    the trip was marked DELIVERED before auto-creation existed.

    Returns None if `trip_id` doesn't exist (main.py -> 404). Raises
    ValueError (main.py -> 400) for domain errors: trip isn't DELIVERED yet,
    or a settlement already exists for this trip — the latter is also
    enforced at the DB level via `trip_id`'s unique constraint, so this
    check is a friendlier error message, not the only thing standing
    between two concurrent requests and a race.
    """
    trip = (
        db.query(models.Trip)
        .options(joinedload(models.Trip.produce_request))
        .filter(models.Trip.id == settlement_in.trip_id)
        .first()
    )
    if not trip:
        return None

    if trip.status != "DELIVERED":
        raise ValueError(
            f"Trip must be DELIVERED before it can be settled (current status: {trip.status})"
        )

    existing = (
        db.query(models.Settlement.id).filter(models.Settlement.trip_id == trip.id).first()
    )
    if existing:
        raise ValueError("A settlement already exists for this trip")

    pr = trip.produce_request
    weight_kg = (
        float(pr.weight_kg)
        if pr is not None and pr.weight_kg is not None
        else 0.0
    )

    values = _compute_settlement_values(
        weight_kg,
        settlement_in.distance_km,
        settlement_in.rate_per_kg,
    )

    db_settlement = models.Settlement(
        trip_id=trip.id,
        rider_id=trip.rider_id,
        farmer_id=pr.farmer_id if pr is not None else None,
        crop_name=pr.crop_type if pr is not None else None,
        quantity_kg=weight_kg,
        base_fare=values["base_fare"],
        distance_fare=values["distance_fare"],
        weight_surcharge=values["weight_surcharge"],
        total_payout=values["rider_fare"],
        gross_amount=values["gross_amount"],
        rider_fare=values["rider_fare"],
        platform_fee=values["platform_fee"],
        net_payout=values["net_payout"],
        status="PENDING",
    )

    try:
        db.add(db_settlement)
        db.commit()
        db.refresh(db_settlement)
        return db_settlement
    except SQLAlchemyError:
        # Covers the concurrent-request race the `existing` check above
        # can't fully close: if two requests for the same trip both pass
        # that check before either commits, the second commit here hits
        # the DB's unique constraint on trip_id and raises IntegrityError
        # (a subclass of SQLAlchemyError) instead of silently creating a
        # duplicate payout.
        db.rollback()
        raise


def get_settlements_for_user(
    db: Session, user_id: UUID, role: str
) -> List[models.Settlement]:
    """
    Role-based payout history. Both roles see their own settlements,
    newest first:

      - FARMER: rows where `farmer_id == user_id` (net sale proceeds to them)
      - RIDER:  rows where `rider_id == user_id` (their fare earnings)

    Returns an empty list for any other role, and for either role with no
    matching rows. Callers in main.py translate the empty list into a 200
    with `[]` automatically — no 404/500 for the "no settlements yet" case.
    """
    query = db.query(models.Settlement)

    if role == "FARMER":
        query = query.filter(models.Settlement.farmer_id == user_id)
    elif role == "RIDER":
        query = query.filter(models.Settlement.rider_id == user_id)
    else:
        # Unknown / unhandled role — return empty rather than 500. This
        # shouldn't fire in practice since require_role gates the signup
        # path, but failing closed here is safer than leaking another
        # user's financial rows.
        return []

    return query.order_by(models.Settlement.created_at.desc()).all()


# ---------------------------------------------------------------------------
# Admin analytics
# ---------------------------------------------------------------------------

def get_admin_stats(db: Session) -> schemas.AdminStatsResponse:
    """
    Platform-wide summary counts. Each is a separate COUNT/SUM query rather
    than one grouped query, since the underlying tables (users, trips,
    settlements) aren't related in a way that a single GROUP BY could
    produce all six numbers from — a users/trips join would double-count
    trips per farmer/rider, for instance. Six small aggregate queries on
    indexed columns (id, status, role) is the simpler and cheaper approach
    here over one convoluted multi-join query.
    """
    total_users = db.query(func.count(models.User.id)).scalar() or 0
    total_farmers = (
        db.query(func.count(models.User.id)).filter(models.User.role == "FARMER").scalar() or 0
    )
    total_riders = (
        db.query(func.count(models.User.id)).filter(models.User.role == "RIDER").scalar() or 0
    )
    total_trips = db.query(func.count(models.Trip.id)).scalar() or 0
    completed_trips = (
        db.query(func.count(models.Trip.id)).filter(models.Trip.status == "DELIVERED").scalar() or 0
    )
    # coalesce to 0.0 so an empty settlements table returns 0.0 rather than
    # None (SUM over zero rows is NULL, not 0, in SQL).
    total_payout_volume = (
        db.query(func.coalesce(func.sum(models.Settlement.total_payout), 0.0)).scalar() or 0.0
    )

    return schemas.AdminStatsResponse(
        total_users=total_users,
        total_farmers=total_farmers,
        total_riders=total_riders,
        total_trips=total_trips,
        completed_trips=completed_trips,
        total_payout_volume=float(total_payout_volume),
    )