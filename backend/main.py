"""
KisanRider FastAPI application.

Merge the endpoints below into your existing main.py (keep your current
/db-check endpoint as-is — it's reproduced here only for completeness).
"""

from typing import List
from uuid import UUID

from fastapi import Depends, FastAPI, HTTPException, Query
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

import crud
import schemas
from database import get_db

app = FastAPI(title="KisanRider API")


# ---------------------------------------------------------------------------
# Health / diagnostics (existing)
# ---------------------------------------------------------------------------

@app.get("/db-check")
def db_check(db: Session = Depends(get_db)):
    try:
        result = db.execute(text("SELECT PostGIS_Version();")).fetchone()
        return {"database": "Connected", "postgis_version": result[0]}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database connection failed: {str(e)}")


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

@app.post("/users/", response_model=schemas.UserResponse, status_code=201)
def register_user(user: schemas.UserCreate, db: Session = Depends(get_db)):
    """Register a new farmer or rider."""
    if crud.get_user_by_phone(db, user.phone):
        raise HTTPException(status_code=400, detail="Phone number already registered")

    try:
        return crud.create_user(db, user)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Produce Requests
# ---------------------------------------------------------------------------

@app.post("/produce-requests/", response_model=schemas.ProduceRequestResponse, status_code=201)
def create_produce_request(
    request: schemas.ProduceRequestCreate,
    farmer_id: UUID = Query(
        ...,
        description="TODO: derive this from an authenticated session/JWT once auth is added; "
        "accepted as a query param for now.",
    ),
    db: Session = Depends(get_db),
):
    """Create a produce pickup request tied to a farmer, storing a PostGIS point."""
    farmer = crud.get_user_by_id(db, farmer_id)
    if not farmer:
        raise HTTPException(status_code=404, detail="Farmer not found")
    if farmer.role != "FARMER":
        raise HTTPException(status_code=400, detail="Only users with role FARMER can create produce requests")

    try:
        return crud.create_produce_request(db, request, farmer_id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/produce-requests/nearby", response_model=List[schemas.NearbyProduceRequestResponse])
def nearby_produce_requests(
    lat: float = Query(..., ge=-90, le=90, description="Rider's current latitude"),
    lng: float = Query(..., ge=-180, le=180, description="Rider's current longitude"),
    radius_km: float = Query(10, gt=0, le=200, description="Search radius in kilometers"),
    db: Session = Depends(get_db),
) -> List[schemas.NearbyProduceRequestResponse]:
    """Return PENDING produce requests within radius_km of the given point, nearest first."""
    try:
        return crud.get_nearby_produce_requests(db, lat=lat, lng=lng, radius_km=radius_km)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/produce-requests/{request_id}", response_model=schemas.ProduceRequestResponse)
def get_produce_request(request_id: UUID, db: Session = Depends(get_db)):
    try:
        result = crud.get_produce_request_by_id(db, request_id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))
    if not result:
        raise HTTPException(status_code=404, detail="Produce request not found")
    return result


# ---------------------------------------------------------------------------
# Trips
# ---------------------------------------------------------------------------

@app.post("/trips/accept", response_model=schemas.TripResponse, status_code=201)
def accept_trip(
    request_id: UUID = Query(..., description="ID of the produce request being accepted"),
    rider_id: UUID = Query(
        ...,
        description="TODO: derive this from an authenticated session/JWT once auth is added; "
        "accepted as a query param for now.",
    ),
    db: Session = Depends(get_db),
):
    """
    A rider accepts a PENDING produce request, creating a Trip and moving
    the request to 'ACCEPTED'. Fails with 400 if the request doesn't exist
    or is no longer PENDING (already accepted/cancelled/etc).
    """
    rider = crud.get_user_by_id(db, rider_id)
    if not rider:
        raise HTTPException(status_code=404, detail="Rider not found")
    if rider.role != "RIDER":
        raise HTTPException(status_code=400, detail="Only users with role RIDER can accept produce requests")

    try:
        return crud.accept_produce_request(db, request_id, rider_id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.patch("/trips/{trip_id}/status", response_model=schemas.TripResponse)
def update_trip_status(trip_id: UUID, body: schemas.TripStatusUpdate, db: Session = Depends(get_db)):
    """
    Transition a trip to PICKED_UP, DELIVERED, or CANCELLED.

    Transitioning to DELIVERED also marks the underlying produce request as
    COMPLETED. Trips already in a terminal state (DELIVERED/CANCELLED)
    reject further updates with a 400.
    """
    try:
        result = crud.update_trip_status(db, trip_id, body.status)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))
    if not result:
        raise HTTPException(status_code=404, detail="Trip not found")
    return result


@app.get("/trips/active", response_model=schemas.ActiveTripResponse)
def get_active_trip(
    rider_id: UUID = Query(..., description="Rider to look up the current active trip for"),
    db: Session = Depends(get_db),
):
    """
    Return the rider's current active trip (status ACCEPTED or PICKED_UP),
    including the pickup coordinates and crop details of the associated
    produce request. 404 if the rider has no active trip right now.
    """
    trip = crud.get_active_trip_for_rider(db, rider_id)
    if not trip:
        raise HTTPException(status_code=404, detail="No active trip found for this rider")

    try:
        produce_request = crud._to_response(trip.produce_request)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    return schemas.ActiveTripResponse(
        id=trip.id,
        produce_request_id=trip.produce_request_id,
        rider_id=trip.rider_id,
        status=trip.status,
        created_at=trip.created_at,
        completed_at=trip.completed_at,
        produce_request=produce_request,
    )