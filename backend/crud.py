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

from typing import List, Optional
from uuid import UUID

from geoalchemy2 import Geography, Geometry
from geoalchemy2.elements import WKTElement
from geoalchemy2.functions import ST_DWithin, ST_Distance, ST_MakePoint, ST_SetSRID, ST_X, ST_Y
from geoalchemy2.shape import to_shape
from sqlalchemy import cast
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from datetime import datetime

import models
import schemas


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
    """
    try:
        point_wkt = WKTElement(
            f"POINT({request_schema.longitude} {request_schema.latitude})",
            srid=4326,
        )
    except Exception as e:
        raise ValueError(f"Invalid coordinates ({request_schema.latitude}, {request_schema.longitude}): {e}") from e

    db_request = models.ProduceRequest(
        farmer_id=farmer_id,
        crop_type=request_schema.crop_type,
        crate_count=request_schema.crate_count,
        weight_kg=request_schema.weight_kg,
        pickup_location=point_wkt,
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
        status=db_request.status,
        created_at=db_request.created_at,
    )


def get_produce_request_by_id(db: Session, request_id: UUID) -> Optional[schemas.ProduceRequestResponse]:
    pr = db.query(models.ProduceRequest).filter(models.ProduceRequest.id == request_id).first()
    return _to_response(pr) if pr else None


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
            status=row.status,
            created_at=row.created_at,
            distance_km=round(row.distance_km, 3),
        )
        for row in rows
    ]


# ---------------------------------------------------------------------------
# Trip CRUD
# ---------------------------------------------------------------------------

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


def update_trip_status(db: Session, trip_id: UUID, status: str) -> Optional[models.Trip]:
    """
    Transition a Trip to a new status ('PICKED_UP', 'DELIVERED', or
    'CANCELLED' — enforced upstream by schemas.TripStatusUpdate).

    Returns None if the trip doesn't exist, so main.py can raise a 404 the
    same way it already does for get_produce_request_by_id. Everything else
    (terminal-state guard) is a domain error raised as ValueError, which
    main.py maps to 400 — same layering as accept_produce_request.

    On transition to 'DELIVERED': stamps `completed_at` and also marks the
    linked ProduceRequest as 'COMPLETED', since a delivered trip means the
    produce has reached its destination. On 'CANCELLED': also stamps
    `completed_at` (CANCELLED is terminal) but leaves the ProduceRequest
    status untouched — reopening it for another rider is a separate concern
    this endpoint doesn't own.

    Both the Trip and its ProduceRequest are row-locked for the duration of
    the transaction, consistent with accept_produce_request, so a status
    update can't race another writer touching the same rows.
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

        db.commit()
        db.refresh(trip)
        return trip
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise