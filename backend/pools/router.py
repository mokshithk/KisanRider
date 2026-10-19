"""
FastAPI router for the KisanRider farmer-pooling feature.

Auth:
  * All farm-side endpoints (create, join, approve, reject, leave, cancel,
    read-one) require ``auth.require_role("FARMER")``.
  * ``GET /pools/nearby`` allows any authenticated user
    (``auth.get_current_user``) so a rider can preview pools.
  * ``POST /pools/{id}/accept`` (Phase 3) requires
    ``auth.require_role("RIDER")``.

Route ordering: ``/nearby`` is registered **before** ``/{pool_id}``. The
UUID path converter would otherwise 422 on the string literal "nearby".
"""

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

import auth
import models
from database import get_db
from pools import crud as pool_crud
from pools import models as pool_models
from pools import schemas as pool_schemas


router = APIRouter(prefix="/pools", tags=["pools"])


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

@router.post(
    "/",
    response_model=pool_schemas.PoolDetailOut,
    status_code=201,
    summary="Create a pooling request (creator becomes first member)",
)
def create_pool(
    payload: pool_schemas.PoolCreate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Create a pool from one of the caller's PENDING ProduceRequests.

    The creator is automatically added as the first PoolMember with
    status ACCEPTED, their weight initialises ``current_qty``, and a
    first PoolStop is generated so the route has an anchor.

    ``auto_approve`` selects the join mode (D3 = 3B):

      * ``True``  — auto-match pool; joins land as ACCEPTED.
      * ``False`` — manual pool; joins land as REQUESTED until approved.
    """
    try:
        pool = pool_crud.create_pool(db, payload, current_user.id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    return pool_crud.to_pool_detail_out(db, pool)


# ---------------------------------------------------------------------------
# Discover — MUST be registered before /{pool_id}
# ---------------------------------------------------------------------------

@router.get(
    "/nearby",
    response_model=list[pool_schemas.PoolOut],
    summary="Browse OPEN pools near a farmer, ordered by distance",
)
def get_nearby_pools(
    lat: float = Query(..., ge=-90, le=90, description="Farmer's latitude"),
    lng: float = Query(..., ge=-180, le=180, description="Farmer's longitude"),
    radius_km: float = Query(
        10, gt=0, le=200, description="Search radius in kilometers"
    ),
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Return OPEN pools whose creator's ProduceRequest pickup location is
    within ``radius_km`` of ``(lat, lng)``.

    Distance is computed from the creator's ProduceRequest geometry —
    pools themselves don't carry a geometry column, so the pool's first
    member (the creator) acts as the anchor.

    Results are ordered closest-first and capped at 50 pools.
    """
    try:
        return pool_crud.get_nearby_pools(
            db, lat=lat, lng=lng, radius_km=radius_km
        )
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")


# ---------------------------------------------------------------------------
# Read one
# ---------------------------------------------------------------------------

@router.get(
    "/{pool_id}",
    response_model=pool_schemas.PoolDetailOut,
    summary="Get full pool detail (members + stops)",
)
def get_pool_detail(
    pool_id: UUID,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Return the full ``PoolDetailOut`` for one pool.

    Access rule: the caller must be the creator, an active member
    (REQUESTED or ACCEPTED), **or** the pool must be OPEN (public
    discovery). Otherwise → 404 (existence not leaked).
    """
    pool = pool_crud.get_pool_by_id(db, pool_id)
    if pool is None:
        raise HTTPException(status_code=404, detail="Pool not found")

    is_creator = pool.creator_id == current_user.id
    is_open = pool.status == pool_models.PoolStatus.OPEN.value
    is_member = any(
        m.farmer_id == current_user.id
        and m.status in ("REQUESTED", "ACCEPTED")
        for m in pool.members
    )

    if not (is_creator or is_open or is_member):
        raise HTTPException(status_code=404, detail="Pool not found")

    return pool_crud.to_pool_detail_out(db, pool)


# ---------------------------------------------------------------------------
# Join
# ---------------------------------------------------------------------------

@router.post(
    "/{pool_id}/join",
    response_model=pool_schemas.PoolDetailOut,
    summary="Join a pool (auto-approve or request, per Pool.auto_approve)",
)
def join_pool(
    pool_id: UUID,
    payload: pool_schemas.PoolMemberCreate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Join a pool with one of the caller's PENDING ProduceRequests.

    Behaviour depends on ``Pool.auto_approve``:

      * **auto** — member is created ACCEPTED, ``current_qty`` increases
        immediately, and a PoolStop is generated.
      * **manual** — member is created REQUESTED. The creator must
        approve it for the weight to count.

    Capacity is checked at join time in both modes; approval re-checks
    against the then-current state.
    """
    try:
        pool = pool_crud.join_pool(
            db, pool_id, current_user.id, payload
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    return pool_crud.to_pool_detail_out(db, pool)


# ---------------------------------------------------------------------------
# Approve / reject
# ---------------------------------------------------------------------------

@router.post(
    "/{pool_id}/members/{member_id}/approve",
    response_model=pool_schemas.PoolDetailOut,
    summary="Approve a REQUESTED pool member (creator only)",
)
def approve_member(
    pool_id: UUID,
    member_id: UUID,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Approve a member whose request is in REQUESTED status.

    Capacity is re-checked against the pool's current ``current_qty``.
    On success the member moves to ACCEPTED, ``current_qty`` increases,
    and a PoolStop is created.
    """
    try:
        pool = pool_crud.approve_member(
            db, pool_id, member_id, current_user.id
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    return pool_crud.to_pool_detail_out(db, pool)


@router.post(
    "/{pool_id}/members/{member_id}/reject",
    response_model=pool_schemas.PoolDetailOut,
    summary="Reject a REQUESTED pool member (creator only)",
)
def reject_member(
    pool_id: UUID,
    member_id: UUID,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Reject a member whose request is in REQUESTED status. Pure state
    flip — a REQUESTED member never incremented ``current_qty``.
    """
    try:
        pool = pool_crud.reject_member(
            db, pool_id, member_id, current_user.id
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    return pool_crud.to_pool_detail_out(db, pool)


# ---------------------------------------------------------------------------
# Leave
# ---------------------------------------------------------------------------

@router.delete(
    "/{pool_id}/leave",
    summary="Leave a pool (only while OPEN; creator leaving cancels the pool)",
)
def leave_pool(
    pool_id: UUID,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Remove the caller's active membership from a pool.

    Only allowed while the pool is OPEN. If the caller was an ACCEPTED
    member, their weight is deducted from ``current_qty`` and their
    PoolStop is marked SKIPPED.

    **Creator-leaves policy**: the pool is automatically CANCELLED and
    every other active member is moved to WITHDRAWN.
    """
    try:
        pool = pool_crud.leave_pool(db, pool_id, current_user.id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    return {
        "success": True,
        "message": "Left pool successfully",
        "pool_id": str(pool_id),
        "pool_status": pool.status,
    }


# ---------------------------------------------------------------------------
# Cancel
# ---------------------------------------------------------------------------

@router.delete(
    "/{pool_id}",
    summary="Cancel a pool (creator only; all active members → WITHDRAWN)",
)
def cancel_pool(
    pool_id: UUID,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Cancel a pool the caller created.

    Flips the pool to CANCELLED, zeroes ``current_qty``, and moves every
    active member (REQUESTED or ACCEPTED) to WITHDRAWN. Cancelling an
    already-CANCELLED or COMPLETED pool is a 400.
    """
    try:
        pool_crud.cancel_pool(db, pool_id, current_user.id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    return {
        "success": True,
        "message": "Pool cancelled",
        "pool_id": str(pool_id),
    }


# ---------------------------------------------------------------------------
# Phase 3 — Rider accepts a pool (creates N Trips, one per member)
# ---------------------------------------------------------------------------

@router.post(
    "/{pool_id}/accept",
    response_model=pool_schemas.PoolAcceptResult,
    status_code=201,
    summary="Accept a pool as a rider (creates one Trip per accepted member)",
)
def accept_pool(
    pool_id: UUID,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Accept an OPEN pool as the authenticated rider.

    Per D1 = Option A, this creates **one Trip per ACCEPTED PoolMember**.
    Every linked ProduceRequest is flipped from PENDING → ACCEPTED so it
    drops out of ``GET /trips/available`` and can no longer be accepted
    individually.

    The response carries the resulting pool status and the IDs of the
    new trips, so the rider's client can immediately navigate to any of
    them without a second lookup.

    ## Error cases (400)
    - Pool not found / not OPEN
    - Pool has no committed weight
    - Pool has no accepted members
    - Any linked ProduceRequest isn't PENDING (defensive — should never
      happen if Phase 2's commitment guards did their job)

    ## Auth
    ``require_role("RIDER")`` — a farmer cannot accept their own pool.
    """
    try:
        pool, trip_ids = pool_crud.accept_pool(
            db, pool_id, current_user.id
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    return pool_schemas.PoolAcceptResult(
        pool_id=pool.id,
        pool_status=pool.status,
        trip_ids=trip_ids,
        trips_created=len(trip_ids),
    )