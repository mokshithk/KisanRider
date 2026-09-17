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

from typing import Optional
from uuid import UUID

from geoalchemy2 import Geography
from geoalchemy2.elements import WKTElement
from geoalchemy2.functions import ST_Distance, ST_DWithin
from geoalchemy2.shape import to_shape
from sqlalchemy import cast
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

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
    """Convert an ORM row (with a WKBElement geometry) into the API schema."""
    point = to_shape(pr.pickup_location)  # shapely Point; .x = lng, .y = lat
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
    point_wkt = WKTElement(
        f"POINT({request_schema.longitude} {request_schema.latitude})",
        srid=4326,
    )
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
        return _to_response(db_request)
    except SQLAlchemyError:
        db.rollback()
        raise


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
) -> list[schemas.NearbyProduceRequestResponse]:
    """
    Find produce requests within `radius_km` of (lat, lng), nearest first.

    Casts both the stored point and the query point to `geography` so
    ST_DWithin/ST_Distance operate in meters over a real ellipsoidal model,
    not raw lat/lng degrees.
    """
    query_point = WKTElement(f"POINT({lng} {lat})", srid=4326)
    query_point_geog = cast(query_point, Geography)
    stored_point_geog = cast(models.ProduceRequest.pickup_location, Geography)

    distance_m = ST_Distance(stored_point_geog, query_point_geog)

    query = db.query(models.ProduceRequest, distance_m.label("distance_m")).filter(
        ST_DWithin(stored_point_geog, query_point_geog, radius_km * 1000)
    )

    if status_filter:
        query = query.filter(models.ProduceRequest.status == status_filter)

    query = query.order_by(distance_m.asc()).limit(limit)

    results: list[schemas.NearbyProduceRequestResponse] = []
    for pr, distance_m_value in query.all():
        base = _to_response(pr)
        results.append(
            schemas.NearbyProduceRequestResponse(
                **base.model_dump(),
                distance_km=round(distance_m_value / 1000, 3),
            )
        )
    return results