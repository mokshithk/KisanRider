"""
CRUD layer for KisanRider farmer pooling.
"""

from datetime import datetime
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
    )


def to_pool_detail_out(
    db: Session,
    pool: pool_models.Pool,
    *,
    creator_full_name: Optional[str] = None,
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

    # Fetch member names
    member_outs = []
    for m in members:
        farmer = db.query(models.User).filter(models.User.id == m.farmer_id).first()
        m_out = pool_schemas.PoolMemberOut.model_validate(m)
        m_out.farmer_full_name = farmer.full_name if farmer else None
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
            max_qty=1000.0,  # Hardcoded backend default per Phase 6 spec
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

    # Use outerjoin for members to ensure pools without members don't crash
    query = (
        db.query(pool, distance_km)
        .outerjoin(pm, pm.pool_id == pool.id)
        .outerjoin(pr, pr.id == pm.produce_request_id)
        .filter(
            pool.status == pool_models.PoolStatus.OPEN.value,
            pool.creator_id != current_user_id, # Prevent seeing own pool
            ST_DWithin(stored_geog, query_point_geog, radius_km * 1000),
        )
    )

    if mandi_id:
        query = query.filter(pool.dropoff_mandi_id == mandi_id)

    # Anchor on creator's PR, but if no PR, still fetch it (dist will be None)
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


def accept_pool(db: Session, pool_id: UUID, rider_id: UUID) -> Tuple[pool_models.Pool, List[UUID]]:
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.status != pool_models.PoolStatus.OPEN.value:
            raise ValueError(f"Pool is not OPEN (current: {pool.status})")
        if float(pool.current_qty) <= 0:
            raise ValueError("Pool has no committed weight; cannot accept")

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