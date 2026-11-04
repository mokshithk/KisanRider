import random
"""
CRUD layer for KisanRider farmer pooling.
"""

from datetime import datetime, timezone, timedelta
from typing import List, Optional, Tuple
from uuid import UUID

from geoalchemy2 import Geography
from geoalchemy2.functions import (
    ST_DWithin,
    ST_Distance,
    ST_MakePoint,
    ST_SetSRID,
)
from geoalchemy2.shape import to_shape
from sqlalchemy import cast, func, select, or_
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, joinedload

import models
from pools import models as pool_models
from pools import schemas as pool_schemas


_ACTIVE_MEMBER_STATUSES = (
    "REQUESTED",
    "ACCEPTED",
    "PENDING",
    "APPROVED",
)


def _now() -> datetime:
    return datetime.utcnow()


def _get_locked_pool(db: Session, pool_id: UUID) -> Optional[pool_models.Pool]:
    return (
        db.query(pool_models.Pool)
        .filter(pool_models.Pool.id == pool_id)
        .with_for_update()
        .first()
    )


def _get_locked_member(db: Session, pool_id: UUID, member_id: UUID) -> Optional[pool_models.PoolMember]:
    return (
        db.query(pool_models.PoolMember)
        .filter(
            pool_models.PoolMember.id == member_id,
            pool_models.PoolMember.pool_id == pool_id,
        )
        .with_for_update()
        .first()
    )


def _verify_produce_request_usable(
    db: Session,
    produce_request_id: UUID,
    farmer_id: UUID,
    *,
    exclude_pool_id: Optional[UUID] = None,
) -> models.ProduceRequest:
    pr = (
        db.query(models.ProduceRequest)
        .filter(models.ProduceRequest.id == produce_request_id)
        .first()
    )
    if pr is None:
        raise ValueError("Produce request not found")
    if pr.farmer_id != farmer_id:
        raise ValueError("Produce request does not belong to you")
    if pr.status != "PENDING":
        raise ValueError(f"Produce request must be PENDING (current status: {pr.status})")

    q = db.query(pool_models.PoolMember).filter(
        pool_models.PoolMember.produce_request_id == produce_request_id,
        pool_models.PoolMember.status.in_(_ACTIVE_MEMBER_STATUSES),
    )
    if exclude_pool_id is not None:
        q = q.filter(pool_models.PoolMember.pool_id != exclude_pool_id)
    if q.first() is not None:
        raise ValueError("Produce request is already part of another active pool")

    return pr


def _create_pool_stop(db: Session, pool_id: UUID, produce_request_id: UUID) -> pool_models.PoolStop:
    existing_skipped = (
        db.query(pool_models.PoolStop)
        .filter(
            pool_models.PoolStop.pool_id == pool_id,
            pool_models.PoolStop.produce_request_id == produce_request_id,
            pool_models.PoolStop.status == "SKIPPED",
        )
        .first()
    )
    if existing_skipped is not None:
        existing_skipped.status = "PENDING"
        return existing_skipped

    max_seq = (
        db.query(func.max(pool_models.PoolStop.sequence))
        .filter(pool_models.PoolStop.pool_id == pool_id)
        .scalar()
    )
    new_stop = pool_models.PoolStop(
        pool_id=pool_id,
        produce_request_id=produce_request_id,
        sequence=(max_seq or 0) + 1,
        status="PENDING",
    )
    db.add(new_stop)
    return new_stop


def _skip_pool_stop(db: Session, pool_id: UUID, produce_request_id: UUID) -> None:
    stop = (
        db.query(pool_models.PoolStop)
        .filter(
            pool_models.PoolStop.pool_id == pool_id,
            pool_models.PoolStop.produce_request_id == produce_request_id,
            pool_models.PoolStop.status == "PENDING",
        )
        .first()
    )
    if stop is not None:
        stop.status = "SKIPPED"


def to_pool_out(
    db: Session,
    pool: pool_models.Pool,
    *,
    creator_full_name: Optional[str] = None,
    distance_km: Optional[float] = None,
) -> pool_schemas.PoolOut:
    if creator_full_name is None:
        creator = db.query(models.User).filter(models.User.id == pool.creator_id).first()
        creator_full_name = creator.full_name if creator else None

    accepted_count = (
        db.query(func.count(pool_models.PoolMember.id))
        .filter(
            pool_models.PoolMember.pool_id == pool.id,
            pool_models.PoolMember.status.in_(("ACCEPTED", "APPROVED")),
        )
        .scalar()
    ) or 0

    # Fetch creator's ProduceRequest for pickup address
    creator_member = (
        db.query(pool_models.PoolMember)
        .filter(
            pool_models.PoolMember.pool_id == pool.id,
            pool_models.PoolMember.farmer_id == pool.creator_id,
        )
        .first()
    )
    pickup_address = None
    if creator_member:
        pr = db.query(models.ProduceRequest).filter(models.ProduceRequest.id == creator_member.produce_request_id).first()
        if pr:
            pickup_address = pr.pickup_address

    # Driver details
    driver_name = None
    driver_phone = None
    driver_vehicle = None
    if pool.status == pool_models.PoolStatus.DRIVER_ASSIGNED.value:
        trip = db.query(models.Trip).filter(models.Trip.pool_id == pool.id).first()
        if trip and trip.rider:
            driver_name = trip.rider.full_name
            driver_phone = trip.rider.phone_number
            driver_vehicle = trip.rider.vehicle_number

    # Estimated Cost (Using base 10km for pool fare estimation)
    from crud import _compute_settlement_values
    values = _compute_settlement_values(float(pool.current_qty), 10.0, 40.0)
    estimated_freight = values["rider_fare"]

    return pool_schemas.PoolOut(
        id=pool.id,
        creator_id=pool.creator_id,
        creator_full_name=creator_full_name,
        crop_type=pool.crop_type,
        pickup_window_start=pool.pickup_window_start,
        pickup_window_end=pool.pickup_window_end,
        min_qty=pool.min_qty,
        max_qty=pool.max_qty,
        current_qty=pool.current_qty,
        status=pool.status,
        auto_approve=pool.auto_approve,
        dropoff_district=pool.dropoff_district,
        dropoff_mandi_id=pool.dropoff_mandi_id,
        dropoff_mandi_name=pool.dropoff_mandi_name,
        dropoff_stall_number=pool.dropoff_stall_number,
        notes=pool.notes,
        member_count=accepted_count,
        created_at=pool.created_at,
        locked_at=pool.locked_at,
        distance_km=distance_km,
        pickup_address=pickup_address,
        estimated_freight=estimated_freight,
        driver_name=driver_name,
        driver_phone=driver_phone,
        driver_vehicle=driver_vehicle,
    )


def to_pool_detail_out(
    db: Session,
    pool: pool_models.Pool,
    *,
    creator_full_name: Optional[str] = None,
    requesting_user_id: Optional[UUID] = None,
) -> pool_schemas.PoolDetailOut:
    base = to_pool_out(db, pool, creator_full_name=creator_full_name)

    members = (
        db.query(pool_models.PoolMember)
        .filter(pool_models.PoolMember.pool_id == pool.id)
        .order_by(pool_models.PoolMember.requested_at.asc())
        .all()
    )
    stops = (
        db.query(pool_models.PoolStop)
        .filter(pool_models.PoolStop.pool_id == pool.id)
        .order_by(pool_models.PoolStop.sequence.asc())
        .all()
    )

    member_outs = []
    for m in members:
        farmer = db.query(models.User).filter(models.User.id == m.farmer_id).first()
        m_out = pool_schemas.PoolMemberOut.model_validate(m)
        m_out.farmer_full_name = farmer.full_name if farmer else None
        if requesting_user_id and m.farmer_id == requesting_user_id:
            pr = db.query(models.ProduceRequest).filter(models.ProduceRequest.id == m.produce_request_id).first()
            if pr and pr.pickup_otp:
                m_out.pickup_otp = pr.pickup_otp
        member_outs.append(m_out)

    return pool_schemas.PoolDetailOut(
        **base.model_dump(),
        members=member_outs,
        stops=[pool_schemas.PoolStopOut.model_validate(s) for s in stops],
    )


def create_pool(
    db: Session,
    pool_data: pool_schemas.PoolCreate,
    creator_id: UUID,
) -> pool_models.Pool:
    try:
        _verify_produce_request_usable(db, pool_data.produce_request_id, creator_id)

        pool = pool_models.Pool(
            creator_id=creator_id,
            crop_type=pool_data.crop_type,
            dropoff_district=pool_data.dropoff_district,
            dropoff_mandi_id=pool_data.dropoff_mandi_id,
            dropoff_mandi_name=pool_data.dropoff_mandi_name,
            dropoff_stall_number=pool_data.dropoff_stall_number,
            pickup_window_start=pool_data.pickup_window_start,
            pickup_window_end=pool_data.pickup_window_end,
            min_qty=pool_data.min_qty,
            max_qty=1000.0,
            current_qty=float(pool_data.weight_kg),
            status=pool_models.PoolStatus.OPEN.value,
            auto_approve=pool_data.auto_approve,
            notes=pool_data.notes,
        )
        db.add(pool)
        db.flush()

        creator_member = pool_models.PoolMember(
            pool_id=pool.id,
            farmer_id=creator_id,
            produce_request_id=pool_data.produce_request_id,
            weight_kg=float(pool_data.weight_kg),
            status=pool_models.PoolMemberStatus.ACCEPTED.value,
            decided_at=_now(),
        )
        db.add(creator_member)
        _create_pool_stop(db, pool.id, pool_data.produce_request_id)

        db.commit()
        db.refresh(pool)
        return pool
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise


def get_pool_by_id(db: Session, pool_id: UUID) -> Optional[pool_models.Pool]:
    return (
        db.query(pool_models.Pool)
        .options(joinedload(pool_models.Pool.members), joinedload(pool_models.Pool.stops))
        .filter(pool_models.Pool.id == pool_id)
        .first()
    )


def get_nearby_pools(
    db: Session,
    lat: float,
    lng: float,
    radius_km: float,
    current_user_id: UUID,
    mandi_id: Optional[str] = None,
    limit: int = 50,
) -> List[pool_schemas.PoolOut]:
    pr = models.ProduceRequest
    pm = pool_models.PoolMember
    pool = pool_models.Pool

    query_point = ST_SetSRID(ST_MakePoint(lng, lat), 4326)
    query_point_geog = cast(query_point, Geography)
    stored_geog = cast(pr.pickup_location, Geography)
    
    distance_km = (ST_Distance(stored_geog, query_point_geog) / 1000.0).label("distance_km")

    # Filter by status OPEN, not creator, within radius, and NOT EXPIRED
    query = (
        db.query(pool, distance_km)
        .outerjoin(pm, pm.pool_id == pool.id)
        .outerjoin(pr, pr.id == pm.produce_request_id)
        .filter(
            pool.status == pool_models.PoolStatus.OPEN.value,
            pool.creator_id != current_user_id,
            pool.pickup_window_end > datetime.utcnow(), # EXPIRED FILTER
            ST_DWithin(stored_geog, query_point_geog, radius_km * 1000),
        )
    )

    if mandi_id:
        query = query.filter(pool.dropoff_mandi_id == mandi_id)

    query = query.filter(
        or_(
            pm.farmer_id == pool.creator_id,
            pm.id.is_(None)
        )
    )

    rows = query.order_by(distance_km.asc()).limit(limit).all()

    if not rows:
        return []

    creator_ids = {p.creator_id for p, _ in rows}
    creators = {u.id: u for u in db.query(models.User).filter(models.User.id.in_(creator_ids)).all()}

    return [
        to_pool_out(
            db,
            p,
            creator_full_name=(creators[p.creator_id].full_name if p.creator_id in creators else None),
            distance_km=round(float(dist), 2) if dist is not None else None,
        )
        for p, dist in rows
    ]


def get_my_pools(db: Session, farmer_id: UUID) -> List[pool_schemas.PoolOut]:
    pm = pool_models.PoolMember
    pool = pool_models.Pool

    rows = (
        db.query(pool)
        .join(pm, pm.pool_id == pool.id)
        .filter(
            pm.farmer_id == farmer_id,
            pm.status.in_(_ACTIVE_MEMBER_STATUSES)
        )
        .order_by(pool.created_at.desc())
        .all()
    )
    return [to_pool_out(db, p) for p in rows]


def join_pool(
    db: Session,
    pool_id: UUID,
    farmer_id: UUID,
    member_data: pool_schemas.PoolMemberCreate,
) -> pool_models.Pool:
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.status != pool_models.PoolStatus.OPEN.value:
            raise ValueError(f"Pool is not OPEN (current: {pool.status})")

        _verify_produce_request_usable(db, member_data.produce_request_id, farmer_id)

        would_be = float(pool.current_qty) + float(member_data.weight_kg)
        if would_be > float(pool.max_qty):
            raise ValueError(f"Capacity exceeded: current {pool.current_qty} kg + requested {member_data.weight_kg} kg > max {pool.max_qty} kg")

        is_auto = bool(pool.auto_approve)
        new_member = pool_models.PoolMember(
            pool_id=pool.id,
            farmer_id=farmer_id,
            produce_request_id=member_data.produce_request_id,
            weight_kg=float(member_data.weight_kg),
            status=(pool_models.PoolMemberStatus.ACCEPTED.value if is_auto else pool_models.PoolMemberStatus.REQUESTED.value),
            decided_at=_now() if is_auto else None,
        )
        db.add(new_member)
        db.flush()

        if is_auto:
            pool.current_qty = would_be
            _create_pool_stop(db, pool.id, member_data.produce_request_id)

        db.commit()
        db.refresh(pool)
        return pool
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise


def approve_member(db: Session, pool_id: UUID, member_id: UUID, creator_id: UUID) -> pool_models.Pool:
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.creator_id != creator_id:
            raise ValueError("Only the pool creator can approve members")
        if pool.status != pool_models.PoolStatus.OPEN.value:
            raise ValueError(f"Pool is not OPEN (current: {pool.status})")

        member = _get_locked_member(db, pool_id, member_id)
        if member is None:
            raise ValueError("Member not found")

        if member.status not in (pool_models.PoolMemberStatus.REQUESTED.value, pool_models.PoolMemberStatus.PENDING.value):
            raise ValueError(f"Member is not in REQUESTED state (current: {member.status})")

        would_be = float(pool.current_qty) + float(member.weight_kg)
        if would_be > float(pool.max_qty):
            raise ValueError(f"Approval would exceed pool capacity: {pool.current_qty} kg + {member.weight_kg} kg > max {pool.max_qty} kg")

        member.status = pool_models.PoolMemberStatus.ACCEPTED.value
        member.decided_at = _now()
        pool.current_qty = would_be
        _create_pool_stop(db, pool.id, member.produce_request_id)

        db.commit()
        db.refresh(pool)
        return pool
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise


def reject_member(db: Session, pool_id: UUID, member_id: UUID, creator_id: UUID, reason: Optional[str] = None) -> pool_models.Pool:
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.creator_id != creator_id:
            raise ValueError("Only the pool creator can reject members")

        member = _get_locked_member(db, pool_id, member_id)
        if member is None:
            raise ValueError("Member not found")

        if member.status not in (pool_models.PoolMemberStatus.REQUESTED.value, pool_models.PoolMemberStatus.PENDING.value):
            raise ValueError(f"Member is not in REQUESTED state (current: {member.status})")

        member.status = pool_models.PoolMemberStatus.REJECTED.value
        member.decided_at = _now()
        if reason and reason.strip():
            member.cancellation_reason = reason.strip()

        db.commit()
        db.refresh(pool)
        return pool
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise


def leave_pool(db: Session, pool_id: UUID, farmer_id: UUID, reason: Optional[str] = None) -> pool_models.Pool:
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.status != pool_models.PoolStatus.OPEN.value:
            raise ValueError(f"Cannot leave: pool is not OPEN (current: {pool.status})")

        member = (
            db.query(pool_models.PoolMember)
            .filter(
                pool_models.PoolMember.pool_id == pool_id,
                pool_models.PoolMember.farmer_id == farmer_id,
                pool_models.PoolMember.status.in_(_ACTIVE_MEMBER_STATUSES),
            )
            .with_for_update()
            .first()
        )
        if member is None:
            raise ValueError("You are not an active member of this pool")

        was_accepted = member.status in (pool_models.PoolMemberStatus.ACCEPTED.value, pool_models.PoolMemberStatus.APPROVED.value)

        member.status = pool_models.PoolMemberStatus.WITHDRAWN.value
        member.decided_at = _now()
        if reason and reason.strip():
            member.cancellation_reason = reason.strip()

        if was_accepted:
            pool.current_qty = max(0.0, float(pool.current_qty) - float(member.weight_kg))
            _skip_pool_stop(db, pool.id, member.produce_request_id)

        if farmer_id == pool.creator_id:
            pool.status = pool_models.PoolStatus.CANCELLED.value
            pool.locked_at = _now()

            others = (
                db.query(pool_models.PoolMember)
                .filter(
                    pool_models.PoolMember.pool_id == pool.id,
                    pool_models.PoolMember.id != member.id,
                    pool_models.PoolMember.status.in_(_ACTIVE_MEMBER_STATUSES),
                )
                .all()
            )
            for other in others:
                other.status = pool_models.PoolMemberStatus.WITHDRAWN.value
                other.decided_at = _now()
                if not other.cancellation_reason:
                    other.cancellation_reason = "Pool cancelled"

        db.commit()
        db.refresh(pool)
        return pool
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise


def cancel_pool(db: Session, pool_id: UUID, creator_id: UUID, reason: Optional[str] = None) -> pool_models.Pool:
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.creator_id != creator_id:
            raise ValueError("Only the pool creator can cancel the pool")

        if pool.status in (pool_models.PoolStatus.CANCELLED.value, pool_models.PoolStatus.COMPLETED.value):
            raise ValueError(f"Pool is already in a terminal state ({pool.status})")

        pool.status = pool_models.PoolStatus.CANCELLED.value
        pool.locked_at = _now()
        pool.current_qty = 0.0

        active_members = (
            db.query(pool_models.PoolMember)
            .filter(
                pool_models.PoolMember.pool_id == pool.id,
                pool_models.PoolMember.status.in_(_ACTIVE_MEMBER_STATUSES),
            )
            .all()
        )
        for m in active_members:
            m.status = pool_models.PoolMemberStatus.WITHDRAWN.value
            m.decided_at = _now()
            if not m.cancellation_reason:
                m.cancellation_reason = (reason.strip() if reason and reason.strip() else "Pool cancelled by creator")

        db.commit()
        db.refresh(pool)
        return pool
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise


def accept_pool(
    db: Session,
    pool_id: UUID,
    rider_id: UUID,
    rider_expected_pickup_at: Optional[datetime] = None,
) -> Tuple[pool_models.Pool, List[UUID]]:
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.status != pool_models.PoolStatus.OPEN.value:
            raise ValueError(f"Pool is not OPEN (current: {pool.status})")
        if float(pool.current_qty) <= 0:
            raise ValueError("Pool has no committed weight; cannot accept")

        now_utc = datetime.now(timezone.utc)
        p_end = pool.pickup_window_end
        if p_end.tzinfo is None:
            p_end = p_end.replace(tzinfo=timezone.utc)
        if p_end <= now_utc:
            pool.status = "CANCELLED"
            db.commit()
            raise ValueError("This pool pickup window has expired and cannot be accepted.")

        p_start = pool.pickup_window_start
        if p_start.tzinfo is None:
            p_start = p_start.replace(tzinfo=timezone.utc)

        if rider_expected_pickup_at is not None:
            if rider_expected_pickup_at.tzinfo is None:
                rider_expected_pickup_at = rider_expected_pickup_at.replace(tzinfo=timezone.utc)
            if rider_expected_pickup_at < p_start:
                raise ValueError(f"Expected pickup time cannot be earlier than pool pickup window start ({p_start.isoformat()}).")
            if rider_expected_pickup_at > p_end:
                raise ValueError(f"Expected pickup time cannot be later than pool pickup window end ({p_end.isoformat()}).")
        else:
            rider_expected_pickup_at = p_start

        accepted_members = (
            db.query(pool_models.PoolMember)
            .filter(
                pool_models.PoolMember.pool_id == pool_id,
                pool_models.PoolMember.status == pool_models.PoolMemberStatus.ACCEPTED.value,
            )
            .all()
        )
        if not accepted_members:
            raise ValueError("Pool has no accepted members")

        rider = db.query(models.User).filter(models.User.id == rider_id).first()
        if rider:
            missing = []
            if not (rider.full_name and rider.full_name.strip()):
                missing.append("Full Name")
            phone = (rider.phone_number or rider.phone or "").strip()
            if not phone:
                missing.append("Contact Phone")
            if not (rider.vehicle_type and rider.vehicle_type.strip()):
                missing.append("Vehicle Type")
            if not (rider.vehicle_number and rider.vehicle_number.strip()):
                missing.append("Vehicle Number")
            if rider.payload_capacity_kg is None or rider.payload_capacity_kg <= 0:
                missing.append("Payload Capacity")
            if not (rider.license_number and rider.license_number.strip()):
                missing.append("License Number")
            if not (rider.district and rider.district.strip()):
                missing.append("Operating District")
            if not (rider.operating_routes and rider.operating_routes.strip()):
                missing.append("Operating Routes")
            if missing:
                raise ValueError(f"Please complete your profile before accepting pools: {', '.join(missing)}.")

            if rider.payload_capacity_kg is not None and float(pool.current_qty) > float(rider.payload_capacity_kg):
                raise ValueError(
                    f"Total pool quantity ({pool.current_qty} kg) exceeds your vehicle capacity ({rider.payload_capacity_kg} kg)."
                )

        pending_members = (
            db.query(pool_models.PoolMember)
            .filter(
                pool_models.PoolMember.pool_id == pool_id,
                pool_models.PoolMember.status.in_((pool_models.PoolMemberStatus.REQUESTED.value, pool_models.PoolMemberStatus.PENDING.value)),
            )
            .all()
        )
        for pm in pending_members:
            pm.status = pool_models.PoolMemberStatus.REJECTED.value
            pm.decided_at = _now()
            if not pm.cancellation_reason:
                pm.cancellation_reason = "Pool assigned to a rider"

        trips_created: List[models.Trip] = []
        used_otps = set()
        for member in accepted_members:
            pr = (
                db.query(models.ProduceRequest)
                .filter(models.ProduceRequest.id == member.produce_request_id)
                .with_for_update()
                .first()
            )
            if pr is None:
                raise ValueError(f"Linked ProduceRequest not found for member {member.id}")
            if pr.status != "PENDING":
                raise ValueError(f"ProduceRequest {pr.id} is not PENDING (current: {pr.status})")

            pr.status = "ACCEPTED"

            # Ensure each farmer in the pool has their own distinct unique 4-digit pickup OTP
            while not pr.pickup_otp or pr.pickup_otp in used_otps:
                pr.pickup_otp = f"{random.randint(1000, 9999)}"
            used_otps.add(pr.pickup_otp)

            pickup_lat: Optional[float] = None
            pickup_lng: Optional[float] = None
            try:
                point = to_shape(pr.pickup_location)
                pickup_lat = float(point.y)
                pickup_lng = float(point.x)
            except Exception:
                pass

            new_trip = models.Trip(
                produce_request_id=pr.id,
                rider_id=rider_id,
                pool_id=pool.id,
                status="ACCEPTED",
                pickup_address=pr.pickup_address,
                pickup_landmark=pr.pickup_landmark,
                pickup_latitude=pickup_lat,
                pickup_longitude=pickup_lng,
                rider_expected_pickup_at=rider_expected_pickup_at,
            )
            db.add(new_trip)
            trips_created.append(new_trip)

        pool.status = pool_models.PoolStatus.DRIVER_ASSIGNED.value
        pool.locked_at = _now()

        db.flush()
        trip_ids = [t.id for t in trips_created]

        db.commit()
        db.refresh(pool)
        return pool, trip_ids
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise


def get_nearby_farmers(db: Session, lat: float, lng: float, radius_km: float, current_farmer_id: UUID, limit: int = 50) -> List[pool_schemas.NearbyFarmerOut]:
    pr = models.ProduceRequest
    pm = pool_models.PoolMember

    query_point = ST_SetSRID(ST_MakePoint(lng, lat), 4326)
    query_point_geog = cast(query_point, Geography)
    stored_geog = cast(pr.pickup_location, Geography)
    distance_km = (ST_Distance(stored_geog, query_point_geog) / 1000.0).label("distance_km")

    active_pool_pr_ids = (
        select(pm.produce_request_id)
        .where(pm.status.in_(("REQUESTED", "ACCEPTED", "PENDING", "APPROVED")))
    )

    try:
        rows = (
            db.query(pr, distance_km)
            .options(joinedload(pr.farmer))
            .filter(pr.status == "PENDING")
            .filter(pr.farmer_id != current_farmer_id)
            .filter(~pr.id.in_(active_pool_pr_ids))
            .filter(ST_DWithin(stored_geog, query_point_geog, radius_km * 1000))
            .order_by(distance_km.asc())
            .limit(limit)
            .all()
        )
    except SQLAlchemyError:
        raise

    result = []
    for row in rows:
        produce_request, dist = row
        farmer_name = produce_request.farmer.full_name if produce_request.farmer else "Farmer"
        result.append(
            pool_schemas.NearbyFarmerOut(
                produce_request_id=produce_request.id,
                farmer_id=produce_request.farmer_id,
                farmer_name=farmer_name,
                crop_type=produce_request.crop_type,
                weight_kg=float(produce_request.weight_kg or 0),
                distance_km=round(float(dist), 2),
                dropoff_mandi_name=produce_request.dropoff_mandi_name,
                dropoff_district=produce_request.dropoff_district,
            )
        )
    return result


def group_pool(db: Session, payload: pool_schemas.PoolGroupCreate, creator_id: UUID) -> pool_models.Pool:
    try:
        creator_pr = (
            db.query(models.ProduceRequest)
            .filter(models.ProduceRequest.id == payload.creator_produce_request_id)
            .with_for_update()
            .first()
        )
        if not creator_pr or creator_pr.farmer_id != creator_id:
            raise ValueError("Invalid creator produce request")
        if creator_pr.status != "PENDING":
            raise ValueError("Creator's produce request is not PENDING")

        other_prs = (
            db.query(models.ProduceRequest)
            .filter(models.ProduceRequest.id.in_(payload.other_produce_request_ids))
            .with_for_update()
            .all()
        )
        if len(other_prs) != len(payload.other_produce_request_ids):
            raise ValueError("One or more selected requests not found")

        for pr in other_prs:
            if pr.status != "PENDING":
                raise ValueError(f"Request {pr.id} is not PENDING")

        all_pr_ids = [creator_pr.id] + [pr.id for pr in other_prs]
        active_pm = (
            db.query(pool_models.PoolMember)
            .filter(
                pool_models.PoolMember.produce_request_id.in_(all_pr_ids),
                pool_models.PoolMember.status.in_(("REQUESTED", "ACCEPTED", "PENDING", "APPROVED")),
            )
            .first()
        )
        if active_pm:
            raise ValueError("One or more selected requests are already in a pool")

        total_weight = float(creator_pr.weight_kg or 0) + sum(float(pr.weight_kg or 0) for pr in other_prs)
        
        pool = pool_models.Pool(
            creator_id=creator_id,
            crop_type=creator_pr.crop_type,
            dropoff_district=creator_pr.dropoff_district,
            dropoff_mandi_id=creator_pr.dropoff_mandi_id,
            dropoff_mandi_name=creator_pr.dropoff_mandi_name,
            dropoff_stall_number=creator_pr.dropoff_stall_number,
            pickup_window_start=payload.pickup_window_start,
            pickup_window_end=payload.pickup_window_end,
            min_qty=total_weight,
            max_qty=1000.0,
            current_qty=total_weight,
            status=pool_models.PoolStatus.OPEN.value,
            auto_approve=True,
        )
        db.add(pool)
        db.flush()

        creator_member = pool_models.PoolMember(
            pool_id=pool.id,
            farmer_id=creator_id,
            produce_request_id=creator_pr.id,
            weight_kg=float(creator_pr.weight_kg or 0),
            status=pool_models.PoolMemberStatus.ACCEPTED.value,
            decided_at=_now(),
        )
        db.add(creator_member)
        _create_pool_stop(db, pool.id, creator_pr.id)

        for pr in other_prs:
            member = pool_models.PoolMember(
                pool_id=pool.id,
                farmer_id=pr.farmer_id,
                produce_request_id=pr.id,
                weight_kg=float(pr.weight_kg or 0),
                status=pool_models.PoolMemberStatus.ACCEPTED.value,
                decided_at=_now(),
            )
            db.add(member)
            _create_pool_stop(db, pool.id, pr.id)

        db.commit()
        db.refresh(pool)
        return pool
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise

def get_pool_route_optimization(
    db: Session,
    pool_id: UUID,
    rider_lat: float,
    rider_lng: float,
) -> dict:
    import sys
    from pathlib import Path
    backend_root = Path(__file__).resolve().parent.parent
    if str(backend_root) not in sys.path:
        sys.path.insert(0, str(backend_root))
    import routing_service

    pool = db.query(pool_models.Pool).filter(pool_models.Pool.id == pool_id).first()
    if pool is None:
        raise ValueError("Pool not found")

    members = (
        db.query(pool_models.PoolMember)
        .filter(pool_models.PoolMember.pool_id == pool_id)
        .filter(pool_models.PoolMember.status.in_((
            pool_models.PoolMemberStatus.ACCEPTED.value,
            pool_models.PoolMemberStatus.REQUESTED.value,
            pool_models.PoolMemberStatus.APPROVED.value,
            pool_models.PoolMemberStatus.PENDING.value,
        )))
        .order_by(pool_models.PoolMember.requested_at.asc())
        .all()
    )

    if not members:
        raise ValueError("No members in this pool")

    farmers_data = []
    dropoff_lat: Optional[float] = None
    dropoff_lng: Optional[float] = None

    for m in members:
        pr = db.query(models.ProduceRequest).filter(models.ProduceRequest.id == m.produce_request_id).first()
        if not pr:
            continue
        farmer = db.query(models.User).filter(models.User.id == m.farmer_id).first()

        f_lat = None
        f_lng = None
        if pr.pickup_location is not None:
            try:
                pt = to_shape(pr.pickup_location)
                f_lat = float(pt.y)
                f_lng = float(pt.x)
            except Exception:
                pass

        if dropoff_lat is None and pr.dropoff_lat and pr.dropoff_lng:
            dropoff_lat = pr.dropoff_lat
            dropoff_lng = pr.dropoff_lng

        linked_trip = db.query(models.Trip).filter(models.Trip.produce_request_id == pr.id).first()
        trip_status = linked_trip.status if linked_trip else pr.status
        trip_id = str(linked_trip.id) if linked_trip else None

        farmers_data.append({
            "id": str(m.id),
            "farmer_id": str(m.farmer_id),
            "produce_request_id": str(pr.id),
            "trip_id": trip_id,
            "status": trip_status,
            "farmer_name": (farmer.full_name if farmer else "Farmer"),
            "farmer_phone": (farmer.phone_number or farmer.phone or "") if farmer else "",
            "crop_type": pr.crop_type,
            "weight_kg": float(m.weight_kg),
            "pickup_address": pr.pickup_address or "Farm Gate",
            "pickup_landmark": pr.pickup_landmark,
            "lat": f_lat,
            "lng": f_lng,
            "requested_pickup_at": (
                pr.requested_pickup_at.isoformat()
                if pr.requested_pickup_at is not None else None
            ),
        })

    # Resolve dropoff location coordinates
    dropoff_name = pool.dropoff_mandi_name or pool.dropoff_district or "Dropoff Mandi"
    if dropoff_lat is None:
        from main import _DISTRICT_CENTERS
        if pool.dropoff_district and pool.dropoff_district in _DISTRICT_CENTERS:
            dropoff_lat, dropoff_lng = _DISTRICT_CENTERS[pool.dropoff_district]
        else:
            dropoff_lat, dropoff_lng = rider_lat, rider_lng

    result = routing_service.optimize_pool_route(
        rider_lat=rider_lat,
        rider_lng=rider_lng,
        dropoff_lat=dropoff_lat,
        dropoff_lng=dropoff_lng,
        dropoff_name=dropoff_name,
        farmers=farmers_data,
    )

    result["pool_id"] = str(pool.id)
    result["crop_type"] = pool.crop_type
    result["pool_status"] = pool.status
    result["pickup_window_start"] = (
        pool.pickup_window_start.isoformat()
        if pool.pickup_window_start is not None else None
    )
    result["pickup_window_end"] = (
        pool.pickup_window_end.isoformat()
        if pool.pickup_window_end is not None else None
    )
    result["dropoff_district"] = pool.dropoff_district
    result["dropoff_mandi_name"] = pool.dropoff_mandi_name
    result["dropoff_stall_number"] = pool.dropoff_stall_number
    result["min_qty"] = pool.min_qty
    result["max_qty"] = pool.max_qty
    result["current_qty"] = pool.current_qty

    return result


def verify_pooled_farmer_otp(
    db: Session,
    pool_id: UUID,
    produce_request_id: UUID,
    otp: str,
    rider_id: UUID,
) -> dict:
    """
    Verifies the individual pickup OTP for a specific farmer in a pool.
    Updates only that farmer's ProduceRequest and Trip to PICKED_UP.
    """
    pool = db.query(pool_models.Pool).filter(pool_models.Pool.id == pool_id).first()
    if not pool:
        raise ValueError("Pool not found")

    trip = (
        db.query(models.Trip)
        .filter(
            models.Trip.pool_id == pool_id,
            models.Trip.produce_request_id == produce_request_id,
        )
        .with_for_update()
        .first()
    )
    if not trip:
        raise ValueError("No trip found for this farmer in the pool")
    if trip.rider_id != rider_id:
        raise ValueError("You are not the assigned rider for this trip")

    if trip.status == "PICKED_UP":
        return {
            "success": True,
            "message": "Pickup already verified for this farmer",
            "produce_request_id": str(produce_request_id),
            "status": "PICKED_UP",
            "already_verified": True,
        }
    if trip.status != "ACCEPTED":
        raise ValueError(f"Trip cannot be verified from status {trip.status}")

    pr_check = db.query(models.ProduceRequest).filter(models.ProduceRequest.id == produce_request_id).first()
    if pr_check and pr_check.pickup_window_end:
        now_utc = datetime.now(timezone.utc)
        p_end = pr_check.pickup_window_end
        if p_end.tzinfo is None:
            p_end = p_end.replace(tzinfo=timezone.utc)
        if p_end <= now_utc:
            trip.status = "MISSED"
            pr_check.status = "EXPIRED"
            db.commit()
            raise ValueError("The pickup window has expired. This pickup is no longer active.")

    pr = (
        db.query(models.ProduceRequest)
        .filter(models.ProduceRequest.id == produce_request_id)
        .with_for_update()
        .first()
    )
    if not pr:
        raise ValueError("Produce request not found")

    submitted = otp.strip()
    if not pr.pickup_otp or submitted != pr.pickup_otp:
        raise ValueError("Invalid OTP. Please check the code with the farmer.")

    pr.status = "PICKED_UP"
    trip.status = "PICKED_UP"
    db.commit()

    pool_trips = db.query(models.Trip).filter(models.Trip.pool_id == pool_id).all()
    all_picked_up = all(t.status in ("PICKED_UP", "DELIVERED") for t in pool_trips) if pool_trips else False

    return {
        "success": True,
        "message": "Pickup verified successfully for farmer",
        "produce_request_id": str(produce_request_id),
        "status": "PICKED_UP",
        "all_picked_up": all_picked_up,
    }
