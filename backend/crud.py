"""
CRUD layer for KisanRider.
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


_PLATFORM_FEE_RATE = 0.02
_DEFAULT_RATE_PER_KG = 40.0
_DEFAULT_DISTANCE_KM = 10.0
_RIDER_PLATFORM_COMMISSION_RATE = 0.02
_DISTANCE_FARE_PER_KM = 15.0


# ---------------------------------------------------------------------------
# User CRUD
# ---------------------------------------------------------------------------

def get_user_by_phone(db: Session, phone: str) -> Optional[models.User]:
    return db.query(models.User).filter(models.User.phone == phone).first()


def get_user_by_email(db: Session, email: str) -> Optional[models.User]:
    normalized = email.strip().lower()
    return (
        db.query(models.User)
        .filter(func.lower(models.User.email) == normalized)
        .first()
    )


def get_user_by_id(db: Session, user_id: UUID) -> Optional[models.User]:
    return db.query(models.User).filter(models.User.id == user_id).first()


def create_user(db: Session, user_schema: schemas.UserCreate) -> models.User:
    db_user = models.User(
        phone=user_schema.phone,
        role=user_schema.role,
        full_name=user_schema.full_name,
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


def update_user_password(
    db: Session, user: models.User, password_hash: str
) -> models.User:
    user.password_hash = password_hash
    try:
        db.commit()
        db.refresh(user)
        return user
    except SQLAlchemyError:
        db.rollback()
        raise


def apply_user_updates(
    db: Session, user: models.User, updates: dict
) -> models.User:
    if not updates:
        return user

    for field, value in updates.items():
        setattr(user, field, value)

    try:
        db.commit()
        db.refresh(user)
        return user
    except SQLAlchemyError:
        db.rollback()
        raise


# ---------------------------------------------------------------------------
# SavedAddress CRUD
# ---------------------------------------------------------------------------

def get_saved_addresses_for_farmer(
    db: Session, farmer_id: UUID
) -> List[models.SavedAddress]:
    return (
        db.query(models.SavedAddress)
        .filter(models.SavedAddress.farmer_id == farmer_id)
        .order_by(models.SavedAddress.created_at.desc())
        .all()
    )


def create_saved_address(
    db: Session,
    farmer_id: UUID,
    *,
    title: str,
    address_text: str,
    landmark: Optional[str],
    latitude: Optional[float],
    longitude: Optional[float],
) -> models.SavedAddress:
    db_address = models.SavedAddress(
        farmer_id=farmer_id,
        title=title.strip(),
        address_text=address_text.strip(),
        landmark=(landmark.strip() if landmark else None) or None,
        latitude=latitude,
        longitude=longitude,
    )
    try:
        db.add(db_address)
        db.commit()
        db.refresh(db_address)
        return db_address
    except SQLAlchemyError:
        db.rollback()
        raise


# ---------------------------------------------------------------------------
# ProduceRequest CRUD
# ---------------------------------------------------------------------------

def _to_response(pr: models.ProduceRequest) -> schemas.ProduceRequestResponse:
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
        weight_kg=float(pr.weight_kg or 0),
        latitude=point.y,
        longitude=point.x,
        pickup_address=pr.pickup_address,
        pickup_landmark=pr.pickup_landmark,
        dropoff_district=pr.dropoff_district,
        dropoff_mandi_id=pr.dropoff_mandi_id,
        dropoff_mandi_name=pr.dropoff_mandi_name,
        dropoff_stall_number=pr.dropoff_stall_number,
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

    dropoff_location = request_schema.dropoff_location
    if not dropoff_location and request_schema.dropoff_mandi_name:
        mandi_name = request_schema.dropoff_mandi_name.strip()
        stall = (request_schema.dropoff_stall_number or "").strip()
        dropoff_location = f"{mandi_name} - {stall}" if stall else mandi_name

    db_request = models.ProduceRequest(
        farmer_id=farmer_id,
        crop_type=request_schema.crop_type,
        weight_kg=request_schema.weight_kg,
        pickup_location=point_wkt,
        pickup_address=request_schema.pickup_address,
        pickup_landmark=request_schema.pickup_landmark,
        dropoff_district=request_schema.dropoff_district,
        dropoff_mandi_id=request_schema.dropoff_mandi_id,
        dropoff_mandi_name=request_schema.dropoff_mandi_name,
        dropoff_stall_number=request_schema.dropoff_stall_number,
        dropoff_location=dropoff_location,
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

    if (
        request_schema.save_address_for_future
        and request_schema.pickup_address
        and request_schema.pickup_address.strip()
    ):
        try:
            title = request_schema.pickup_address.strip()[:60]
            create_saved_address(
                db,
                farmer_id,
                title=title,
                address_text=request_schema.pickup_address,
                landmark=request_schema.pickup_landmark,
                latitude=request_schema.latitude,
                longitude=request_schema.longitude,
            )
        except SQLAlchemyError:
            pass

    return schemas.ProduceRequestResponse(
        id=db_request.id,
        farmer_id=db_request.farmer_id,
        crop_type=db_request.crop_type,
        weight_kg=float(db_request.weight_kg or 0),
        latitude=request_schema.latitude,
        longitude=request_schema.longitude,
        pickup_address=db_request.pickup_address,
        pickup_landmark=db_request.pickup_landmark,
        dropoff_district=db_request.dropoff_district,
        dropoff_mandi_id=db_request.dropoff_mandi_id,
        dropoff_mandi_name=db_request.dropoff_mandi_name,
        dropoff_stall_number=db_request.dropoff_stall_number,
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
    base = _to_response(pr)

    trip_summary = None
    if pr.trip:
        rider = pr.trip.rider
        rider_summary = (
            schemas.RiderSummary(
                id=rider.id,
                full_name=rider.full_name,
                phone=rider.phone or "",
                phone_number=rider.phone_number,
                vehicle_number=rider.vehicle_number,
                vehicle_type=rider.vehicle_type,
            )
            if rider
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
            pr.weight_kg,
            pr.status,
            pr.created_at,
            pr.pickup_address,
            pr.pickup_landmark,
            pr.dropoff_district,
            pr.dropoff_mandi_id,
            pr.dropoff_mandi_name,
            pr.dropoff_stall_number,
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

    query = query.order_by(pr.created_at.desc()).limit(limit)

    try:
        rows = query.all()
    except SQLAlchemyError:
        raise

    return [
        schemas.NearbyProduceRequestResponse(
            id=row.id,
            farmer_id=row.farmer_id,
            crop_type=row.crop_type,
            weight_kg=float(row.weight_kg or 0),
            latitude=row.latitude,
            longitude=row.longitude,
            pickup_address=row.pickup_address,
            pickup_landmark=row.pickup_landmark,
            dropoff_district=row.dropoff_district,
            dropoff_mandi_id=row.dropoff_mandi_id,
            dropoff_mandi_name=row.dropoff_mandi_name,
            dropoff_stall_number=row.dropoff_stall_number,
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

        pickup_lat: Optional[float] = None
        pickup_lng: Optional[float] = None
        try:
            point = to_shape(pr.pickup_location)
            pickup_lat = float(point.y)
            pickup_lng = float(point.x)
        except Exception:
            pass

        db_trip = models.Trip(
            produce_request_id=request_id,
            rider_id=rider_id,
            status="ACCEPTED",
            pickup_address=pr.pickup_address,
            pickup_landmark=pr.pickup_landmark,
            pickup_latitude=pickup_lat,
            pickup_longitude=pickup_lng,
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
# Privacy-aware trip views
# ---------------------------------------------------------------------------

def _first_name(full_name: Optional[str]) -> Optional[str]:
    if not full_name:
        return None
    parts = full_name.strip().split()
    return parts[0] if parts else None


def _estimate_rider_fare(pr: models.ProduceRequest) -> float:
    weight_kg = float(pr.weight_kg or 0)
    values = _compute_settlement_values(
        weight_kg,
        _DEFAULT_DISTANCE_KM,
        _DEFAULT_RATE_PER_KG,
    )
    return round(values["rider_fare"], 2)


def _pickup_latlng(pr: models.ProduceRequest) -> tuple[float, float]:
    try:
        point = to_shape(pr.pickup_location)
        return point.y, point.x
    except Exception:
        return 0.0, 0.0


def _to_trip_available(
    pr: models.ProduceRequest,
) -> schemas.TripAvailableOut:
    farmer = pr.farmer
    lat, lng = _pickup_latlng(pr)

    return schemas.TripAvailableOut(
        trip_id=pr.id,
        crop_type=pr.crop_type,
        weight_kg=float(pr.weight_kg or 0),
        latitude=lat,
        longitude=lng,
        pickup_district=(farmer.district if farmer else None),
        pickup_locality=(farmer.taluk_village if farmer else None),
        pickup_address=pr.pickup_address,
        pickup_landmark=pr.pickup_landmark,
        payout_amount=_estimate_rider_fare(pr),
        status="PENDING",
        farmer_full_name=_first_name(farmer.full_name if farmer else None),
        farmer_phone_number=None,
    )


def _compose_pickup_address(pr: models.ProduceRequest) -> Optional[str]:
    farmer = pr.farmer

    parts: list[str] = []
    if pr.pickup_address:
        parts.append(pr.pickup_address.strip())
    if pr.pickup_landmark:
        parts.append(pr.pickup_landmark.strip())

    if not parts and farmer:
        if farmer.farm_address:
            parts.append(farmer.farm_address.strip())
        if farmer.landmark:
            parts.append(farmer.landmark.strip())

    return "\n".join(p for p in parts if p) or None


def _to_trip_active(
    pr: models.ProduceRequest,
) -> schemas.TripActiveOut:
    trip = pr.trip
    farmer = pr.farmer
    rider = trip.rider if trip else None

    has_rider = (
        trip is not None
        and trip.status in ("ACCEPTED", "PICKED_UP", "DELIVERED")
    )

    pickup_address = (
        trip.pickup_address if trip and trip.pickup_address
        else _compose_pickup_address(pr)
    )
    pickup_landmark = (
        trip.pickup_landmark if trip and trip.pickup_landmark
        else pr.pickup_landmark
    )

    lat, lng = _pickup_latlng(pr)

    return schemas.TripActiveOut(
        trip_id=(trip.id if trip else pr.id),
        produce_request_id=pr.id,
        status=(trip.status if trip else pr.status),
        crop_type=pr.crop_type,
        weight_kg=float(pr.weight_kg or 0),
        latitude=lat,
        longitude=lng,
        pickup_address=pickup_address,
        pickup_landmark=pickup_landmark,
        dropoff_address=pr.dropoff_location,
        dropoff_district=pr.dropoff_district,
        dropoff_mandi_id=pr.dropoff_mandi_id,
        dropoff_mandi_name=pr.dropoff_mandi_name,
        dropoff_stall_number=pr.dropoff_stall_number,
        dropoff_lat=pr.dropoff_lat,
        dropoff_lng=pr.dropoff_lng,
        farmer_full_name=(farmer.full_name if farmer and has_rider else None),
        farmer_phone_number=(
            farmer.phone_number if farmer and has_rider else None
        ),
        rider_full_name=(rider.full_name if rider and has_rider else None),
        rider_phone_number=(
            rider.phone_number if rider and has_rider else None
        ),
        vehicle_number=(rider.vehicle_number if rider and has_rider else None),
        vehicle_type=(rider.vehicle_type if rider and has_rider else None),
    )


def get_available_trips_for_rider(
    db: Session,
    lat: float,
    lng: float,
    radius_km: float,
    limit: int = 50,
) -> List[schemas.TripAvailableOut]:
    pr = models.ProduceRequest

    query_point = ST_SetSRID(ST_MakePoint(lng, lat), 4326)
    query_point_geog = cast(query_point, Geography)
    stored_geog = cast(pr.pickup_location, Geography)

    distance_km = (
        ST_Distance(stored_geog, query_point_geog) / 1000.0
    ).label("distance_km")

    try:
        rows = (
            db.query(pr, distance_km)
            .options(joinedload(pr.farmer))
            .filter(pr.status == "PENDING")
            .filter(ST_DWithin(stored_geog, query_point_geog, radius_km * 1000))
            .order_by(pr.created_at.desc())
            .limit(limit)
            .all()
        )
    except SQLAlchemyError:
        raise

    return [_to_trip_available(row[0]) for row in rows]


def get_active_trips_out_for_rider(
    db: Session, rider_id: UUID
) -> List[schemas.TripActiveOut]:
    trips = (
        db.query(models.Trip)
        .options(
            joinedload(models.Trip.produce_request).joinedload(
                models.ProduceRequest.farmer
            ),
            joinedload(models.Trip.rider),
        )
        .filter(
            models.Trip.rider_id == rider_id,
            models.Trip.status.in_(("ACCEPTED", "PICKED_UP")),
        )
        .order_by(models.Trip.created_at.desc())
        .all()
    )
    return [_to_trip_active(t.produce_request) for t in trips]


def get_trip_active_by_request_id(
    db: Session, request_id: UUID
) -> Optional[schemas.TripActiveOut]:
    pr = (
        db.query(models.ProduceRequest)
        .options(
            joinedload(models.ProduceRequest.farmer),
            joinedload(models.ProduceRequest.trip).joinedload(models.Trip.rider),
        )
        .filter(models.ProduceRequest.id == request_id)
        .first()
    )
    return _to_trip_active(pr) if pr else None


def get_farmer_order(
    db: Session, order_id: UUID, farmer_id: UUID
) -> Optional[schemas.TripActiveOut]:
    pr = (
        db.query(models.ProduceRequest)
        .options(
            joinedload(models.ProduceRequest.farmer),
            joinedload(models.ProduceRequest.trip).joinedload(models.Trip.rider),
        )
        .filter(models.ProduceRequest.id == order_id)
        .first()
    )
    if pr is None or pr.farmer_id != farmer_id:
        return None
    return _to_trip_active(pr)


# ---------------------------------------------------------------------------
# Farmer Order History
# ---------------------------------------------------------------------------

def _order_display_status(pr: models.ProduceRequest) -> str:
    trip = pr.trip
    if trip is not None:
        if trip.status == "DELIVERED":
            return "COMPLETED"
        if trip.status == "CANCELLED":
            return "CANCELLED"
        if trip.status in ("ACCEPTED", "PICKED_UP"):
            return "IN_TRANSIT"

    if pr.status == "COMPLETED":
        return "COMPLETED"
    if pr.status == "CANCELLED":
        return "CANCELLED"
    return pr.status or "PENDING"


def _extract_pickup_village(
    pr: models.ProduceRequest,
    farmer: Optional[models.User],
) -> Optional[str]:
    if farmer is not None and farmer.taluk_village:
        first = farmer.taluk_village.strip().split(",")[0].strip()
        if first:
            return first

    if pr.pickup_address:
        first = pr.pickup_address.strip().split(",")[0].strip()
        if first:
            return first

    return None


def _split_dropoff(
    dropoff_location: Optional[str],
) -> tuple[Optional[str], Optional[str]]:
    if not dropoff_location:
        return None, None

    parts = dropoff_location.split(" - ", 1)
    if len(parts) == 2:
        mandi = parts[0].strip() or None
        stall = parts[1].strip() or None
        return mandi, stall

    return (parts[0].strip() or None), None


def _mandi_and_stall_from_pr(
    pr: models.ProduceRequest,
) -> tuple[Optional[str], Optional[str]]:
    if pr.dropoff_mandi_name:
        return (
            pr.dropoff_mandi_name.strip() or None,
            (pr.dropoff_stall_number or "").strip() or None,
        )
    return _split_dropoff(pr.dropoff_location)


def get_farmer_order_history(
    db: Session, farmer_id: UUID
) -> List[schemas.OrderHistoryItemResponse]:
    rows = (
        db.query(models.ProduceRequest)
        .options(
            joinedload(models.ProduceRequest.farmer),
            joinedload(models.ProduceRequest.trip),
        )
        .filter(models.ProduceRequest.farmer_id == farmer_id)
        .order_by(models.ProduceRequest.created_at.desc())
        .all()
    )

    result: List[schemas.OrderHistoryItemResponse] = []
    for pr in rows:
        mandi_name, stall_number = _mandi_and_stall_from_pr(pr)
        result.append(
            schemas.OrderHistoryItemResponse(
                id=pr.id,
                crop_name=pr.crop_type or "—",
                weight_kg=float(pr.weight_kg or 0),
                status=_order_display_status(pr),
                created_at=pr.created_at,
                pickup_village=_extract_pickup_village(pr, pr.farmer),
                mandi_name=mandi_name,
                stall_number=stall_number,
            )
        )
    return result


def _decode_pickup_coords(
    pr: models.ProduceRequest,
) -> tuple[Optional[float], Optional[float]]:
    try:
        point = to_shape(pr.pickup_location)
        return float(point.y), float(point.x)
    except Exception:
        return None, None


def get_farmer_order_detail(
    db: Session, order_id: UUID, farmer_id: UUID
) -> Optional[schemas.FarmerOrderDetailResponse]:
    pr = (
        db.query(models.ProduceRequest)
        .options(
            joinedload(models.ProduceRequest.farmer),
            joinedload(models.ProduceRequest.trip).joinedload(models.Trip.rider),
            joinedload(models.ProduceRequest.trip).joinedload(
                models.Trip.settlement
            ),
        )
        .filter(models.ProduceRequest.id == order_id)
        .first()
    )
    if pr is None or pr.farmer_id != farmer_id:
        return None

    trip = pr.trip
    rider = trip.rider if trip is not None else None
    settlement = trip.settlement if trip is not None else None

    pickup_lat, pickup_lng = _decode_pickup_coords(pr)

    dropoff_display = pr.dropoff_location
    if not dropoff_display and pr.dropoff_mandi_name:
        stall = (pr.dropoff_stall_number or "").strip()
        dropoff_display = (
            f"{pr.dropoff_mandi_name.strip()} - {stall}"
            if stall
            else pr.dropoff_mandi_name.strip()
        )

    return schemas.FarmerOrderDetailResponse(
        id=pr.id,
        status=_order_display_status(pr),
        trip_status=(trip.status if trip is not None else None),
        created_at=pr.created_at,
        completed_at=(trip.completed_at if trip is not None else None),
        trip_id=(trip.id if trip is not None else None),
        pickup_otp=pr.pickup_otp,
        cancellation_reason=pr.cancellation_reason,
        rider=(
            schemas.OrderRiderInfo(
                id=rider.id,
                full_name=rider.full_name,
                phone_number=rider.phone_number,
                vehicle_type=rider.vehicle_type,
                vehicle_number=rider.vehicle_number,
            )
            if rider is not None
            else None
        ),
        pickup=schemas.OrderLocationInfo(
            address=pr.pickup_address,
            landmark=pr.pickup_landmark,
            latitude=pickup_lat,
            longitude=pickup_lng,
        ),
        dropoff=schemas.OrderLocationInfo(
            address=dropoff_display,
            landmark=None,
            latitude=pr.dropoff_lat,
            longitude=pr.dropoff_lng,
        ),
        crop=schemas.OrderCropInfo(
            crop_name=pr.crop_type or "—",
            weight_kg=float(pr.weight_kg or 0),
        ),
        settlement=(
            schemas.OrderSettlementInfo(
                status=settlement.status,
                gross_amount=settlement.gross_amount,
                rider_fare=settlement.rider_fare,
                platform_fee=settlement.platform_fee,
                net_payout=settlement.net_payout,
                created_at=settlement.created_at,
            )
            if settlement is not None
            else None
        ),
        dropoff_district=pr.dropoff_district,
        dropoff_mandi_name=pr.dropoff_mandi_name,
        dropoff_stall_number=pr.dropoff_stall_number,
    )


# NEW: ---------------------------------------------------------------------
# Farmer Order Edit / Cancel
# ---------------------------------------------------------------------------

_ACCEPTANCE_LOCK_MESSAGE = (
    "Order cannot be modified or cancelled after acceptance"
)

_ORDER_UPDATE_FIELD_MAP = {
    "crop_name": "crop_type",
    "dropoff_mandi": "dropoff_mandi_name",
    "pickup_notes": "pickup_landmark",
    # weight_kg, dropoff_district, dropoff_stall_number pass through
}


def update_farmer_order(
    db: Session,
    order_id: UUID,
    farmer_id: UUID,
    updates: dict,
) -> models.ProduceRequest:
    """
    Apply a partial update to a PENDING produce request.

    Raises ValueError on:
      - order not found / not owned by this farmer
      - order not in PENDING status (accepted trips are locked)

    Empty `updates` is a no-op commit-free path.
    """
    pr = (
        db.query(models.ProduceRequest)
        .filter(models.ProduceRequest.id == order_id)
        .with_for_update()
        .first()
    )
    if pr is None or pr.farmer_id != farmer_id:
        raise ValueError("Order not found")

    if pr.status != "PENDING":
        raise ValueError(_ACCEPTANCE_LOCK_MESSAGE)

    if not updates:
        return pr

    try:
        for field, value in updates.items():
            model_field = _ORDER_UPDATE_FIELD_MAP.get(field, field)
            if model_field == "dropoff_mandi_name":
                # Keep the legacy composite `dropoff_location` in sync so
                # display code that still parses it sees the new name.
                pr.dropoff_mandi_name = value
                stall = (pr.dropoff_stall_number or "").strip()
                pr.dropoff_location = (
                    f"{value} - {stall}" if stall and value else value
                )
            elif model_field == "dropoff_stall_number":
                pr.dropoff_stall_number = value
                mandi = (pr.dropoff_mandi_name or "").strip()
                pr.dropoff_location = (
                    f"{mandi} - {value}" if mandi and value else (mandi or value)
                )
            else:
                setattr(pr, model_field, value)
        db.commit()
        db.refresh(pr)
        return pr
    except SQLAlchemyError:
        db.rollback()
        raise


def cancel_farmer_order(
    db: Session,
    order_id: UUID,
    farmer_id: UUID,
    reason: Optional[str],
) -> models.ProduceRequest:
    """
    Cancel a PENDING produce request.

    Raises ValueError on:
      - order not found / not owned by this farmer
      - order not in PENDING status (accepted trips are locked)

    "Frees any pending locks": because we only ever cancel PENDING orders,
    no Trip row exists yet in the normal flow. As a defensive measure, any
    orphaned Trip in a non-terminal state is also cancelled so no dangling
    active state survives the order's cancellation.
    """
    pr = (
        db.query(models.ProduceRequest)
        .options(joinedload(models.ProduceRequest.trip))
        .filter(models.ProduceRequest.id == order_id)
        .with_for_update()
        .first()
    )
    if pr is None or pr.farmer_id != farmer_id:
        raise ValueError("Order not found")

    if pr.status != "PENDING":
        raise ValueError(_ACCEPTANCE_LOCK_MESSAGE)

    try:
        pr.status = "CANCELLED"
        pr.cancellation_reason = (reason or "").strip() or None

        if pr.trip is not None and pr.trip.status not in (
            "DELIVERED",
            "CANCELLED",
        ):
            pr.trip.status = "CANCELLED"
            pr.trip.completed_at = datetime.utcnow()

        db.commit()
        db.refresh(pr)
        return pr
    except SQLAlchemyError:
        db.rollback()
        raise


# ---------------------------------------------------------------------------
# Rider Trip History
# ---------------------------------------------------------------------------

def _rider_trip_payment_method_list(
    trip: models.Trip,
    settlement: Optional[models.Settlement],
) -> str:
    if trip.status == "CANCELLED":
        return "—"
    if settlement is None:
        return "—"
    if settlement.status == "PAID":
        return "Wallet Credited"
    return "Cash Collected"


def _rider_trip_payment_method_detail(
    trip: models.Trip,
    settlement: Optional[models.Settlement],
) -> str:
    if trip.status == "CANCELLED":
        return "—"
    if settlement is None:
        return "—"
    if settlement.status == "PAID":
        return "QR Payment at Mandi"
    return "Cash in Hand"


def _rider_trip_distance_km(
    settlement: Optional[models.Settlement],
) -> Optional[float]:
    if settlement is None or settlement.distance_fare is None:
        return None
    try:
        return round(float(settlement.distance_fare) / _DISTANCE_FARE_PER_KM, 2)
    except (TypeError, ValueError):
        return None


def get_rider_trip_history(
    db: Session, rider_id: UUID
) -> List[schemas.RiderTripHistoryItemResponse]:
    trips = (
        db.query(models.Trip)
        .options(
            joinedload(models.Trip.produce_request).joinedload(
                models.ProduceRequest.farmer
            ),
            joinedload(models.Trip.settlement),
        )
        .filter(
            models.Trip.rider_id == rider_id,
            models.Trip.status.in_(("DELIVERED", "CANCELLED")),
        )
        .order_by(models.Trip.created_at.desc())
        .all()
    )

    result: List[schemas.RiderTripHistoryItemResponse] = []
    for trip in trips:
        pr = trip.produce_request
        if pr is None:
            continue

        settlement = trip.settlement
        fare_earned = (
            float(settlement.total_payout or 0)
            if settlement is not None and trip.status == "DELIVERED"
            else 0.0
        )

        mandi_name, stall_number = _mandi_and_stall_from_pr(pr)

        result.append(
            schemas.RiderTripHistoryItemResponse(
                id=trip.id,
                crop_name=pr.crop_type or "—",
                weight_kg=float(pr.weight_kg or 0),
                fare_earned=fare_earned,
                status=trip.status,
                created_at=trip.created_at,
                pickup_village=_extract_pickup_village(pr, pr.farmer),
                mandi_name=mandi_name,
                stall_number=stall_number,
                payment_method=_rider_trip_payment_method_list(
                    trip, settlement
                ),
            )
        )
    return result


def get_rider_trip_detail(
    db: Session, trip_id: UUID, rider_id: UUID
) -> Optional[schemas.RiderTripDetailResponse]:
    trip = (
        db.query(models.Trip)
        .options(
            joinedload(models.Trip.produce_request).joinedload(
                models.ProduceRequest.farmer
            ),
            joinedload(models.Trip.settlement),
        )
        .filter(models.Trip.id == trip_id)
        .first()
    )
    if trip is None or trip.rider_id != rider_id:
        return None

    pr = trip.produce_request
    farmer = pr.farmer if pr is not None else None
    settlement = trip.settlement

    pickup_lat = trip.pickup_latitude
    pickup_lng = trip.pickup_longitude
    if pickup_lat is None and pr is not None:
        pickup_lat, pickup_lng = _decode_pickup_coords(pr)

    dropoff_lat = pr.dropoff_lat if pr is not None else None
    dropoff_lng = pr.dropoff_lng if pr is not None else None

    mandi_name, stall_number = (
        _mandi_and_stall_from_pr(pr) if pr is not None else (None, None)
    )

    distance_km = _rider_trip_distance_km(settlement)

    fare = None
    if trip.status == "DELIVERED" and settlement is not None:
        gross = float(settlement.total_payout or 0)
        commission = round(gross * _RIDER_PLATFORM_COMMISSION_RATE, 2)
        net = round(gross - commission, 2)
        fare = schemas.RiderTripFareBreakdown(
            gross_transport_fare=gross,
            platform_commission=commission,
            net_earnings=net,
            payment_method=_rider_trip_payment_method_detail(trip, settlement),
        )

    return schemas.RiderTripDetailResponse(
        id=trip.id,
        status=trip.status,
        completed_at=trip.completed_at,
        distance_km=distance_km,
        farmer=(
            schemas.RiderTripFarmerInfo(
                id=farmer.id,
                full_name=farmer.full_name,
                phone_number=farmer.phone_number,
                farm_address=(farmer.farm_address or farmer.landmark),
            )
            if farmer is not None
            else None
        ),
        pickup=schemas.RiderTripLocationInfo(
            address=(
                trip.pickup_address
                or (pr.pickup_address if pr is not None else None)
            ),
            landmark=(
                trip.pickup_landmark
                or (pr.pickup_landmark if pr is not None else None)
            ),
            latitude=pickup_lat,
            longitude=pickup_lng,
        ),
        mandi=schemas.RiderTripMandiInfo(
            mandi_name=mandi_name,
            trader_name=None,
            stall_number=stall_number,
        ),
        crop=schemas.RiderTripCropInfo(
            crop_name=(pr.crop_type if pr is not None else "—"),
            weight_kg=float(pr.weight_kg or 0) if pr is not None else 0.0,
        ),
        fare=fare,
    )


# ---------------------------------------------------------------------------
# CrateScan CRUD
# ---------------------------------------------------------------------------

def create_crate_scan(
    db: Session, scan_data: schemas.CrateScanCreate, user_id: UUID
) -> Optional[models.CrateScan]:
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
    base_fare = 50.0
    distance_fare = distance_km * _DISTANCE_FARE_PER_KM
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