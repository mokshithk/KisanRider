"""
FastAPI router for the KisanRider farmer-pooling feature.
"""

from typing import Optional
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
    mandi_id: Optional[str] = Query(
        None, description="Filter by dropoff mandi ID"
    ),
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Return OPEN pools whose creator's ProduceRequest pickup location is
    within ``radius_km`` of ``(lat, lng)``.
    """
    try:
        return pool_crud.get_nearby_pools(
            db, 
            lat=lat, 
            lng=lng, 
            radius_km=radius_km, 
            current_user_id=current_user.id, 
            mandi_id=mandi_id
        )
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")


@router.get(
    "/nearby-farmers",
    response_model=list[pool_schemas.NearbyFarmerOut],
    summary="Browse unpooled farmers near the location",
)
def get_nearby_farmers(
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
    radius_km: float = Query(10, gt=0, le=200),
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Return PENDING ProduceRequests near ``(lat, lng)`` that are NOT
    currently part of an active Pool, excluding the current farmer's
    own requests.
    """
    try:
        return pool_crud.get_nearby_farmers(
            db, lat=lat, lng=lng, radius_km=radius_km, current_farmer_id=current_user.id
        )
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")


# ---------------------------------------------------------------------------
# Group (Auto-match)
# ---------------------------------------------------------------------------

@router.post(
    "/group",
    response_model=pool_schemas.PoolDetailOut,
    status_code=201,
    summary="Instantly group selected farmers into a new pool",
)
def group_pool(
    payload: pool_schemas.PoolGroupCreate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Instantly groups the creator and selected farmers into a new pool.
    All members are set to ACCEPTED. The creator must have a PENDING
    produce request to anchor the pool.
    """
    try:
        pool = pool_crud.group_pool(db, payload, current_user.id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except SQLAlchemyError as e:
        raise HTTPException(status_code=500, detail=f"Database error: {e}")

    return pool_crud.to_pool_detail_out(db, pool)


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
    Reject a member whose request is in REQUESTED status.
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