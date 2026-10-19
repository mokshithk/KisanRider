"""
CRUD layer for KisanRider farmer pooling.

Phases:
  * Phase 2 — create / nearby / join / approve / reject / leave / cancel.
  * Phase 3 — adds ``accept_pool``: rider handoff that creates N Trip rows
              (one per ACCEPTED member) per D1 = Option A, and flips the
              pool to ``DRIVER_ASSIGNED``.

Concurrency model
-----------------

Every mutation that touches ``Pool.current_qty`` or ``Pool.status``
acquires a row lock on the Pool row via ``with_for_update()`` before
reading or writing any quantities. This is the same pattern
``crud.accept_produce_request`` uses for ProduceRequest, and it's the
only way two simultaneous joins can never both pass the capacity check.

Duplicate commitments
---------------------

Before creating a PoolMember, we verify that no other **active**
PoolMember is already linked to the same ``produce_request_id``. Active
means REQUESTED or ACCEPTED (plus the Phase 1 legacy aliases PENDING /
APPROVED).

Status vocabulary
-----------------

Phase 2/3 canonical: REQUESTED, ACCEPTED, WITHDRAWN, REJECTED.
Legacy aliases (PENDING, APPROVED, CANCELLED) are treated as their
Phase 2/3 equivalents inside ``_ACTIVE_MEMBER_STATUSES``.
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
from geoalchemy2.shape import to_shape       # Phase 3 — pickup coord snapshot
from sqlalchemy import cast, func
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, joinedload

import models
from pools import models as pool_models
from pools import schemas as pool_schemas


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Statuses that count as "an active commitment". A ProduceRequest can be
# linked to at most one PoolMember in these statuses at a time.
_ACTIVE_MEMBER_STATUSES = (
    "REQUESTED",
    "ACCEPTED",
    # Phase 1 legacy aliases
    "PENDING",
    "APPROVED",
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _now() -> datetime:
    """Single source of truth for "now" inside CRUD (keeps tests sane)."""
    return datetime.utcnow()


def _get_locked_pool(
    db: Session, pool_id: UUID
) -> Optional[pool_models.Pool]:
    """
    Fetch a Pool row with a write lock.

    Callers MUST use this for any mutation that changes ``current_qty`` or
    ``status`` — the row lock is what prevents concurrent joins from
    racing past the capacity check.
    """
    return (
        db.query(pool_models.Pool)
        .filter(pool_models.Pool.id == pool_id)
        .with_for_update()
        .first()
    )


def _get_locked_member(
    db: Session, pool_id: UUID, member_id: UUID
) -> Optional[pool_models.PoolMember]:
    """Fetch a PoolMember row, scoped to its pool, with a write lock."""
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
    """
    Shared validation for both "create pool" and "join pool":

      * the ProduceRequest exists
      * it belongs to the caller
      * it is PENDING
      * it is not already committed to another active pool

    ``exclude_pool_id`` lets the creator flow ignore the pool it's about
    to create.
    """
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
        raise ValueError(
            f"Produce request must be PENDING "
            f"(current status: {pr.status})"
        )

    q = db.query(pool_models.PoolMember).filter(
        pool_models.PoolMember.produce_request_id == produce_request_id,
        pool_models.PoolMember.status.in_(_ACTIVE_MEMBER_STATUSES),
    )
    if exclude_pool_id is not None:
        q = q.filter(pool_models.PoolMember.pool_id != exclude_pool_id)
    if q.first() is not None:
        raise ValueError(
            "Produce request is already part of another active pool"
        )

    return pr


def _create_pool_stop(
    db: Session,
    pool_id: UUID,
    produce_request_id: UUID,
) -> pool_models.PoolStop:
    """
    Append a pickup stop for ``produce_request_id`` to ``pool_id``.

    Idempotent: if a SKIPPED stop already exists for the same PR (member
    withdrew and later rejoined), it's reactivated rather than duplicated.
    """
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


def _skip_pool_stop(
    db: Session, pool_id: UUID, produce_request_id: UUID
) -> None:
    """Mark the pickup stop for ``produce_request_id`` as SKIPPED."""
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


# ---------------------------------------------------------------------------
# Serialisation helpers
# ---------------------------------------------------------------------------

def to_pool_out(
    db: Session,
    pool: pool_models.Pool,
    *,
    creator_full_name: Optional[str] = None,
) -> pool_schemas.PoolOut:
    """Convert a Pool ORM row to ``PoolOut``."""
    if creator_full_name is None:
        creator = (
            db.query(models.User)
            .filter(models.User.id == pool.creator_id)
            .first()
        )
        creator_full_name = creator.full_name if creator else None

    accepted_count = (
        db.query(func.count(pool_models.PoolMember.id))
        .filter(
            pool_models.PoolMember.pool_id == pool.id,
            pool_models.PoolMember.status.in_(
                ("ACCEPTED", "APPROVED")
            ),
        )
        .scalar()
    ) or 0

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
    )


def to_pool_detail_out(
    db: Session,
    pool: pool_models.Pool,
    *,
    creator_full_name: Optional[str] = None,
) -> pool_schemas.PoolDetailOut:
    """Convert a Pool ORM row into the full detail shape."""
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

    return pool_schemas.PoolDetailOut(
        **base.model_dump(),
        members=[pool_schemas.PoolMemberOut.model_validate(m) for m in members],
        stops=[pool_schemas.PoolStopOut.model_validate(s) for s in stops],
    )


# ---------------------------------------------------------------------------
# Lifecycle: create
# ---------------------------------------------------------------------------

def create_pool(
    db: Session,
    pool_data: pool_schemas.PoolCreate,
    creator_id: UUID,
) -> pool_models.Pool:
    """
    Create a Pool and its creator's initial PoolMember.

    The creator is auto-accepted and gets the first PoolStop.
    ``current_qty`` starts at their weight. The creator's ProduceRequest
    is validated to exist, belong to them, be PENDING, and not already
    be in another pool.
    """
    try:
        _verify_produce_request_usable(
            db, pool_data.produce_request_id, creator_id
        )

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
            max_qty=pool_data.max_qty,
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


# ---------------------------------------------------------------------------
# Read: single + nearby
# ---------------------------------------------------------------------------

def get_pool_by_id(
    db: Session, pool_id: UUID
) -> Optional[pool_models.Pool]:
    """
    Load a Pool with members and stops eagerly attached.

    The router uses ``pool.members`` for its access check, so eager-loading
    here avoids a lazy-query 500 in the request path.
    """
    return (
        db.query(pool_models.Pool)
        .options(
            joinedload(pool_models.Pool.members),
            joinedload(pool_models.Pool.stops),
        )
        .filter(pool_models.Pool.id == pool_id)
        .first()
    )


def get_nearby_pools(
    db: Session,
    lat: float,
    lng: float,
    radius_km: float,
    limit: int = 50,
) -> List[pool_schemas.PoolOut]:
    """
    Return OPEN pools whose creator's ProduceRequest pickup point is
    within ``radius_km`` of ``(lat, lng)``.

    Pools have no geometry column of their own; the creator's
    ProduceRequest (the pool's first member) is the anchor via an inner
    join through PoolMember.
    """
    pr = models.ProduceRequest
    pm = pool_models.PoolMember
    pool = pool_models.Pool

    query_point = ST_SetSRID(ST_MakePoint(lng, lat), 4326)
    query_point_geog = cast(query_point, Geography)
    stored_geog = cast(pr.pickup_location, Geography)

    distance_km = (
        ST_Distance(stored_geog, query_point_geog) / 1000.0
    ).label("distance_km")

    try:
        rows = (
            db.query(pool)
            .join(pm, pm.pool_id == pool.id)
            .join(pr, pr.id == pm.produce_request_id)
            .filter(
                pool.status == pool_models.PoolStatus.OPEN.value,
                pm.farmer_id == pool.creator_id,
                ST_DWithin(
                    stored_geog,
                    query_point_geog,
                    radius_km * 1000,
                ),
            )
            .order_by(distance_km.asc())
            .limit(limit)
            .all()
        )
    except SQLAlchemyError:
        raise

    if not rows:
        return []

    creator_ids = {p.creator_id for p in rows}
    creators = {
        u.id: u
        for u in (
            db.query(models.User)
            .filter(models.User.id.in_(creator_ids))
            .all()
        )
    }

    return [
        to_pool_out(
            db,
            p,
            creator_full_name=(
                creators[p.creator_id].full_name
                if p.creator_id in creators
                else None
            ),
        )
        for p in rows
    ]


# ---------------------------------------------------------------------------
# Lifecycle: join
# ---------------------------------------------------------------------------

def join_pool(
    db: Session,
    pool_id: UUID,
    farmer_id: UUID,
    member_data: pool_schemas.PoolMemberCreate,
) -> pool_models.Pool:
    """
    Join a pool as ``farmer_id``.

    Behaviour depends on ``Pool.auto_approve`` (D3 = 3B):

      * auto (True)  — member is created as ACCEPTED, ``current_qty`` is
                       incremented, and a PoolStop is created immediately.
      * manual (False) — member is created as REQUESTED; ``current_qty``
                         and the stops list stay unchanged until the
                         creator approves.

    Capacity is checked in **both** modes at join time (a manual request
    that could never fit is a fast fail rather than a doomed queue entry);
    the approve endpoint re-checks against the then-current ``current_qty``.
    """
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.status != pool_models.PoolStatus.OPEN.value:
            raise ValueError(
                f"Pool is not OPEN (current: {pool.status})"
            )

        _verify_produce_request_usable(
            db, member_data.produce_request_id, farmer_id
        )

        would_be = float(pool.current_qty) + float(member_data.weight_kg)
        if would_be > float(pool.max_qty):
            raise ValueError(
                f"Capacity exceeded: current {pool.current_qty} kg + "
                f"requested {member_data.weight_kg} kg = {would_be} kg "
                f"> max {pool.max_qty} kg"
            )

        is_auto = bool(pool.auto_approve)
        new_member = pool_models.PoolMember(
            pool_id=pool.id,
            farmer_id=farmer_id,
            produce_request_id=member_data.produce_request_id,
            weight_kg=float(member_data.weight_kg),
            status=(
                pool_models.PoolMemberStatus.ACCEPTED.value
                if is_auto
                else pool_models.PoolMemberStatus.REQUESTED.value
            ),
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


# ---------------------------------------------------------------------------
# Lifecycle: approve / reject
# ---------------------------------------------------------------------------

def approve_member(
    db: Session,
    pool_id: UUID,
    member_id: UUID,
    creator_id: UUID,
) -> pool_models.Pool:
    """
    Approve a REQUESTED PoolMember. Creator-only.

    Re-checks capacity against the pool's current state — another
    auto-approved join may have consumed the remaining space between
    the original request and this approval.
    """
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.creator_id != creator_id:
            raise ValueError("Only the pool creator can approve members")
        if pool.status != pool_models.PoolStatus.OPEN.value:
            raise ValueError(
                f"Pool is not OPEN (current: {pool.status})"
            )

        member = _get_locked_member(db, pool_id, member_id)
        if member is None:
            raise ValueError("Member not found")

        if member.status not in (
            pool_models.PoolMemberStatus.REQUESTED.value,
            pool_models.PoolMemberStatus.PENDING.value,
        ):
            raise ValueError(
                f"Member is not in REQUESTED state "
                f"(current: {member.status})"
            )

        would_be = float(pool.current_qty) + float(member.weight_kg)
        if would_be > float(pool.max_qty):
            raise ValueError(
                f"Approval would exceed pool capacity: "
                f"{pool.current_qty} kg + {member.weight_kg} kg = "
                f"{would_be} kg > max {pool.max_qty} kg"
            )

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


def reject_member(
    db: Session,
    pool_id: UUID,
    member_id: UUID,
    creator_id: UUID,
    reason: Optional[str] = None,
) -> pool_models.Pool:
    """
    Reject a REQUESTED PoolMember. Creator-only.

    No capacity changes, no stop removal.
    """
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.creator_id != creator_id:
            raise ValueError("Only the pool creator can reject members")

        member = _get_locked_member(db, pool_id, member_id)
        if member is None:
            raise ValueError("Member not found")

        if member.status not in (
            pool_models.PoolMemberStatus.REQUESTED.value,
            pool_models.PoolMemberStatus.PENDING.value,
        ):
            raise ValueError(
                f"Member is not in REQUESTED state "
                f"(current: {member.status})"
            )

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


# ---------------------------------------------------------------------------
# Lifecycle: leave
# ---------------------------------------------------------------------------

def leave_pool(
    db: Session,
    pool_id: UUID,
    farmer_id: UUID,
    reason: Optional[str] = None,
) -> pool_models.Pool:
    """
    Remove ``farmer_id``'s active membership from ``pool_id``.

    **Creator-leaves policy**: if the creator leaves, the pool is
    **cancelled**. All other active members move to WITHDRAWN.

    For a non-creator:
      * member → WITHDRAWN
      * if the member was ACCEPTED, ``current_qty`` is decremented and
        the member's PoolStop is marked SKIPPED.

    Only allowed while ``pool.status == OPEN``.
    """
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.status != pool_models.PoolStatus.OPEN.value:
            raise ValueError(
                f"Cannot leave: pool is not OPEN "
                f"(current: {pool.status})"
            )

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

        was_accepted = member.status in (
            pool_models.PoolMemberStatus.ACCEPTED.value,
            pool_models.PoolMemberStatus.APPROVED.value,
        )

        member.status = pool_models.PoolMemberStatus.WITHDRAWN.value
        member.decided_at = _now()
        if reason and reason.strip():
            member.cancellation_reason = reason.strip()

        if was_accepted:
            pool.current_qty = max(
                0.0, float(pool.current_qty) - float(member.weight_kg)
            )
            _skip_pool_stop(db, pool.id, member.produce_request_id)

        if farmer_id == pool.creator_id:
            pool.status = pool_models.PoolStatus.CANCELLED.value
            pool.locked_at = _now()

            others = (
                db.query(pool_models.PoolMember)
                .filter(
                    pool_models.PoolMember.pool_id == pool.id,
                    pool_models.PoolMember.id != member.id,
                    pool_models.PoolMember.status.in_(
                        _ACTIVE_MEMBER_STATUSES
                    ),
                )
                .all()
            )
            for other in others:
                other.status = (
                    pool_models.PoolMemberStatus.WITHDRAWN.value
                )
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


# ---------------------------------------------------------------------------
# Lifecycle: cancel
# ---------------------------------------------------------------------------

def cancel_pool(
    db: Session,
    pool_id: UUID,
    creator_id: UUID,
    reason: Optional[str] = None,
) -> pool_models.Pool:
    """
    Cancel a pool. Creator-only.

    Flips ``pool.status`` to CANCELLED, stamps ``locked_at``, zeroes
    ``current_qty``, and moves every active member (REQUESTED / ACCEPTED)
    to WITHDRAWN.
    """
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.creator_id != creator_id:
            raise ValueError("Only the pool creator can cancel the pool")

        if pool.status in (
            pool_models.PoolStatus.CANCELLED.value,
            pool_models.PoolStatus.COMPLETED.value,
        ):
            raise ValueError(
                f"Pool is already in a terminal state ({pool.status})"
            )

        pool.status = pool_models.PoolStatus.CANCELLED.value
        pool.locked_at = _now()
        pool.current_qty = 0.0

        active_members = (
            db.query(pool_models.PoolMember)
            .filter(
                pool_models.PoolMember.pool_id == pool.id,
                pool_models.PoolMember.status.in_(
                    _ACTIVE_MEMBER_STATUSES
                ),
            )
            .all()
        )
        for m in active_members:
            m.status = pool_models.PoolMemberStatus.WITHDRAWN.value
            m.decided_at = _now()
            if not m.cancellation_reason:
                m.cancellation_reason = (
                    reason.strip()
                    if reason and reason.strip()
                    else "Pool cancelled by creator"
                )

        db.commit()
        db.refresh(pool)
        return pool
    except ValueError:
        db.rollback()
        raise
    except SQLAlchemyError:
        db.rollback()
        raise


# ---------------------------------------------------------------------------
# Phase 3 — Lifecycle: rider handoff
# ---------------------------------------------------------------------------

def accept_pool(
    db: Session,
    pool_id: UUID,
    rider_id: UUID,
) -> Tuple[pool_models.Pool, List[UUID]]:
    """
    Accept a pool as a rider and materialise the N-Trips-per-Pool
    handoff (D1 = Option A).

    Pre-conditions:
      * ``pool.status == OPEN``
      * ``pool.current_qty > 0`` (at least the creator is committed)
      * at least one PoolMember is in ACCEPTED state

    What happens on success (inside one transaction, with the Pool row
    locked):

      1. Pool status → ``DRIVER_ASSIGNED``, ``locked_at`` stamped.
      2. Any still-REQUESTED member is marked REJECTED with a clear
         cancellation_reason — otherwise those members would be stranded
         inside a pool that no longer accepts joins or approvals.
      3. For each ACCEPTED member:
         * the linked ProduceRequest is locked and flipped from PENDING
           to ACCEPTED
         * a new Trip is created with ``pool_id`` set and the pickup
           fields snapshotted from the ProduceRequest (same fields
           ``crud.accept_produce_request`` copies onto a Trip)
      4. Return ``(pool, [new_trip_id, ...])``.

    A ProduceRequest that isn't PENDING is a hard 400 — this should never
    happen if Phase 2's "already committed" guards did their job, but a
    defensive check here prevents a half-materialised handoff if the
    data somehow drifted.

    NOTE: the ProduceRequest status flip to ACCEPTED is what removes each
    PR from ``GET /trips/available`` going forward, since that feed
    filters on ``status == PENDING``.
    """
    try:
        pool = _get_locked_pool(db, pool_id)
        if pool is None:
            raise ValueError("Pool not found")
        if pool.status != pool_models.PoolStatus.OPEN.value:
            raise ValueError(
                f"Pool is not OPEN (current: {pool.status})"
            )
        if float(pool.current_qty) <= 0:
            raise ValueError(
                "Pool has no committed weight; cannot accept"
            )

        accepted_members = (
            db.query(pool_models.PoolMember)
            .filter(
                pool_models.PoolMember.pool_id == pool_id,
                pool_models.PoolMember.status
                == pool_models.PoolMemberStatus.ACCEPTED.value,
            )
            .all()
        )
        if not accepted_members:
            raise ValueError("Pool has no accepted members")

        # Close out still-pending requests — the pool is no longer
        # accepting members now that a rider is assigned. This also
        # releases their PRs back to the rider feed via Phase 3's
        # `get_available_trips_for_rider` filter change.
        pending_members = (
            db.query(pool_models.PoolMember)
            .filter(
                pool_models.PoolMember.pool_id == pool_id,
                pool_models.PoolMember.status.in_(
                    (
                        pool_models.PoolMemberStatus.REQUESTED.value,
                        pool_models.PoolMemberStatus.PENDING.value,  # legacy
                    )
                ),
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
                .filter(
                    models.ProduceRequest.id == member.produce_request_id
                )
                .with_for_update()
                .first()
            )
            if pr is None:
                raise ValueError(
                    f"Linked ProduceRequest not found for member "
                    f"{member.id}"
                )
            if pr.status != "PENDING":
                raise ValueError(
                    f"ProduceRequest {pr.id} is not PENDING "
                    f"(current: {pr.status})"
                )

            pr.status = "ACCEPTED"

            # Snapshot pickup coordinates — same pattern as
            # crud.accept_produce_request.
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

        db.flush()  # populate trip IDs
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