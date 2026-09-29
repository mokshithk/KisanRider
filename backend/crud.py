"""
CRUD layer for KisanRider.

Spatial notes:
- pickup_location is stored as geometry(POINT, 4326).
- For distance filtering/sorting we cast to `geography` inline in the query,
  which makes PostGIS compute true great-circle distances in meters over
  the WGS84 spheroid.
"""

import random
from datetime import datetime
from typing import List, Optional
from uuid import UUID

from geoalchemy2 import Geography, Geometry
from geoalchemy2.elements import WKTElement
from geoalchemy2.functions import (
    ST_DWithin,
    ST_Distance,
    ST_MakePoint,
    ST_SetSRID,
    ST_X,
    ST_Y,
)
from geoalchemy2.shape import to_shape
from sqlalchemy import cast, func
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, joinedload

import models
import schemas


# ---------------------------------------------------------------------------
# Settlement economics — single place to tune the money math
# ---------------------------------------------------------------------------

_PLATFORM_FEE_RATE = 0.02  # 2%
_DEFAULT_RATE_PER_KG = 40.0  # ₹ per kg
_DEFAULT_DISTANCE_KM = 10.0


# ---------------------------------------------------------------------------
# User CRUD
# ---------------------------------------------------------------------------

def get_user_by_phone(db: Session, phone: str) -> Optional[models.User]:
    """Legacy lookup — used by the /users/ endpoint and dev tooling."""
    return db.query(models.User).filter(models.User.phone == phone).first()


def get_user_by_email(db: Session, email: str) -> Optional[models.User]:
    """
    Primary lookup for the email-based signup/login flow.

    Case-insensitive because email is case-insensitive in practice.
    """
    normalized = email.strip().lower()
    return (
        db.query(models.User)
        .filter(func.lower(models.User.email) == normalized)
        .first()
    )


def get_user_by_id(db: Session, user_id: UUID) -> Optional[models.User]:
    return db.query(models.User).filter(models.User.id == user_id).first()


def create_user(db: Session, user_schema: schemas.UserCreate) -> models.User:
    """Legacy /users/ path — no email, no password, no OTP. Kept for compat."""
    db_user = models.User(
        phone=user_schema.phone,
        role=user_schema.role,
        full_name=user_schema.full_name,
        # Synthesize an email so the NOT NULL constraint holds. The
        # @legacy. domain marks these as phone-only accounts.
        email=f"{user_schema.phone}@legacy.kisanrider.local",
        is_verified=True,
    )
    try:
        db.add(db_user)
        db.commit()
        db.refresh(db_user)
        return db_user
    except SQLAlchemyError:
        db.rollback()
        raise


def create_user_signup(
    db: Session,
    *,
    email: str,
    password_hash: str,
    role: str,
    full_name: str,
    district: Optional[str],
    state: Optional[str],
) -> models.User:
    """
    Insert a user created through the email-OTP signup flow.

    The caller is responsible for hashing the password; passing an
    already-hashed value keeps this function framework-agnostic (no
    passlib import here) and prevents an accidental plaintext column
    write.

    Email is lowercased before insert so it matches what
    get_user_by_email expects on lookup. `phone` is left null — this
    flow doesn't collect one. `is_verified` is set True because we only
    reach this function after OTP verification has succeeded.
    """
    db_user = models.User(
        email=email.strip().lower(),
        role=role,
        full_name=full_name,
        password_hash=password_hash,
        district=district,
        state=state,
        is_verified=True,
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
    """Convert an ORM row (with WKBElement geometry) into the API schema."""
    try:
        point = to_shape(pr.pickup_location)
    except Exception as e:
        raise ValueError(
            f"Could not decode stored geometry for produce request {pr.id}: {e}"
        ) from e

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
    """Insert a produce request; generates the pickup OTP."""
    try:
        point_wkt = WKTElement(
            f"POINT({request_schema.longitude} {request_schema.latitude})",
            srid=4326,
        )
    except Exception as e:
        raise ValueError(
            f"Invalid coordinates "
            f"({request_schema.latitude}, {request_schema.longitude}): {e}"
        ) from e

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


def get_produce_request_by_id(
    db: Session, request_id: UUID
) -> Optional[schemas.ProduceRequestResponse]:
    pr = (
        db.query(models.ProduceRequest)
        .filter(models.ProduceRequest.id == request_id)
        .first()
    )
    return _to_response(pr) if pr else None


def _to_farmer_response(
    pr: models.ProduceRequest,
) -> schemas.FarmerProduceRequestResponse:
    """Extend _to_response() with the request's trip (if any) and its rider."""
    base = _to_response(pr)

    trip_summary = None
    if pr.trip:
        rider_summary = (
            schemas.RiderSummary(
                id=pr.trip.rider.id,
                full_name=pr.trip.rider.full_name,
                phone=pr.trip.rider.phone or "",
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
    """All produce requests a farmer has created, newest first."""
    requests = (
        db.query(models.ProduceRequest)
        .options(
            joinedload(models.ProduceRequest.trip).joinedload(models.Trip.rider)
        )
        .filter(models.ProduceRequest.farmer_id == farmer_id)
        .order_by(models.ProduceRequest.created_at.desc())
        .all()
    )
    return [_to_farmer_response(pr) for pr in requests]


def get_farmer_produce_requests(
    db: Session, farmer_id: UUID
) -> List[schemas.ProduceRequestResponse]:
    """All produce requests created by `farmer_id`, newest first (flat view)."""
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
    """Find PENDING produce requests within `radius_km` of (lat, lng), nearest first."""
    pr = models.ProduceRequest

    query_point = ST_SetSRID(ST_MakePoint(lng, lat), 4326)
    query_point_geog = cast(query_point, Geography)
    stored_geog = cast(pr.pickup_location, Geography)
    stored_geom = cast(pr.pickup_location, Geometry)

    distance_km = (
        ST_Distance(stored_geog, query_point_geog) / 1000.0
    ).label("distance_km")
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
    """Pickup-handoff confirmation; flips the ProduceRequest to PICKED_UP on match."""
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
            f"Request must be ACCEPTED before OTP verification "
            f"(current status: {pr.status})"
        )

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
    return db.query(models.Trip).filter(models.Trip.id == trip_id).first()


def accept_produce_request(
    db: Session, request_id: UUID, rider_id: UUID
) -> models.Trip:
    """A rider accepts a PENDING produce request, creating a Trip."""
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
    """Transition a Trip; on DELIVERED, also mark the request COMPLETED
    and auto-create a Settlement."""
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
            raise ValueError(
                f"Trip is already in a terminal state ({trip.status}) "
                f"and cannot be updated"
            )

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


def get_active_trips_for_rider(
    db: Session, rider_id: UUID
) -> List[models.Trip]:
    """All of the rider's active trips (ACCEPTED or PICKED_UP), newest first."""
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
    """Record a crate QR-code scan against a trip; None if trip doesn't exist."""
    trip_exists = (
        db.query(models.Trip.id)
        .filter(models.Trip.id == scan_data.trip_id)
        .first()
    )
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
    """Single source of truth for the fare/payout arithmetic."""
    base_fare = 50.0
    distance_fare = distance_km * 15.0
    weight_surcharge = max(0.0, weight_kg - 50.0) * 2.0
    rider_fare = base_fare + distance_fare + weight_surcharge

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
    """Create a Settlement row for `trip` if one doesn't already exist."""
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
    db.add(db_settlement)
    return db_settlement


def create_settlement(
    db: Session, settlement_in: schemas.SettlementCreate
) -> Optional[models.Settlement]:
    """Manual / admin creation of a settlement for a DELIVERED trip."""
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
            f"Trip must be DELIVERED before it can be settled "
            f"(current status: {trip.status})"
        )

    existing = (
        db.query(models.Settlement.id)
        .filter(models.Settlement.trip_id == trip.id)
        .first()
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
        db.rollback()
        raise


def get_settlements_for_user(
    db: Session, user_id: UUID, role: str
) -> List[models.Settlement]:
    """Role-based payout history — FARMER filters on farmer_id, RIDER on rider_id."""
    query = db.query(models.Settlement)

    if role == "FARMER":
        query = query.filter(models.Settlement.farmer_id == user_id)
    elif role == "RIDER":
        query = query.filter(models.Settlement.rider_id == user_id)
    else:
        return []

    return query.order_by(models.Settlement.created_at.desc()).all()


# ---------------------------------------------------------------------------
# Admin analytics
# ---------------------------------------------------------------------------

def get_admin_stats(db: Session) -> schemas.AdminStatsResponse:
    """Platform-wide summary counts."""
    total_users = db.query(func.count(models.User.id)).scalar() or 0
    total_farmers = (
        db.query(func.count(models.User.id))
        .filter(models.User.role == "FARMER")
        .scalar()
        or 0
    )
    total_riders = (
        db.query(func.count(models.User.id))
        .filter(models.User.role == "RIDER")
        .scalar()
        or 0
    )
    total_trips = db.query(func.count(models.Trip.id)).scalar() or 0
    completed_trips = (
        db.query(func.count(models.Trip.id))
        .filter(models.Trip.status == "DELIVERED")
        .scalar()
        or 0
    )
    total_payout_volume = (
        db.query(func.coalesce(func.sum(models.Settlement.total_payout), 0.0)).scalar()
        or 0.0
    )

    return schemas.AdminStatsResponse(
        total_users=total_users,
        total_farmers=total_farmers,
        total_riders=total_riders,
        total_trips=total_trips,
        completed_trips=completed_trips,
        total_payout_volume=float(total_payout_volume),
    )