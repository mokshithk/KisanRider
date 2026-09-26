"""
KisanRider FastAPI application.

Merge the endpoints below into your existing main.py (keep your current
/db-check endpoint as-is — it's reproduced here only for completeness).
"""

import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import List
from uuid import UUID

from fastapi import Depends, FastAPI, File, HTTPException, Query, UploadFile
from fastapi.staticfiles import StaticFiles
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

import auth
import crud
import models
import schemas
from database import engine, get_db
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="KisanRider API")

# Allows Flutter Web on any local port to interact with FastAPI
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Create any tables defined in models.py that don't exist yet in Postgres
    (e.g. crate_scans) on startup.

    create_all() only issues CREATE TABLE IF NOT EXISTS for tables it
    doesn't find — it never touches a table that already exists, so it
    won't add/drop/alter a column on your existing users/produce_requests/
    trips tables no matter how their models.py definition has drifted from
    the live schema. That's exactly why the CrateScan model added a couple
    of rounds ago never actually created crate_scans in Postgres: nothing
    had called create_all() since that model was added, so every insert
    into it 500'd with "relation crate_scans does not exist" — the bare,
    non-JSON error body you're seeing is Postgres's error escaping past
    every try/except in crud.py/main.py, none of which catch a missing-
    table error specifically.

    For anything beyond "table doesn't exist yet" — an actual schema
    change to a column that already exists — create_all() does nothing;
    you'd need a real migration tool (Alembic) or a manual SQL script.
    """
    models.Base.metadata.create_all(bind=engine)
    yield


app = FastAPI(title="KisanRider API", lifespan=lifespan)

# Local static storage for delivery photos (see POST /uploads/delivery-photo
# below). Swap this whole block for real Supabase Storage in production —
# local disk storage doesn't survive a redeploy on most hosts and doesn't
# scale past one server instance.
UPLOAD_DIR = Path("static/uploads")
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory="static"), name="static")

ALLOWED_UPLOAD_CONTENT_TYPES = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
}
MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB


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
# Dev-only auth (local testing in Swagger UI)
# ---------------------------------------------------------------------------

@app.post("/auth/dev-token")
def issue_dev_token(
    user_id: UUID = Query(..., description="Existing user to mint a test token for"),
    db: Session = Depends(get_db),
):
    """
    Mint a short-lived access token for an existing user, for exercising
    protected endpoints from Swagger UI without going through Supabase Auth.

    404s in production (ENVIRONMENT=production) rather than merely
    rejecting the token mint — DEV_MODE is checked before touching the DB
    at all, so this route has zero attack surface once deployed for real:
    it behaves as if it doesn't exist. It's a complete auth bypass by
    design (any real user_id in, a valid token for that user out, no
    password), which is exactly why it can't be reachable outside
    development.
    """
    if not auth.DEV_MODE:
        raise HTTPException(status_code=404, detail="Not found")

    user = crud.get_user_by_id(db, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    token = auth.create_dev_token(user_id)
    return {"access_token": token, "token_type": "bearer"}


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
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """Create a produce pickup request tied to the authenticated farmer, storing a PostGIS point."""
    try:
        return crud.create_produce_request(db, request, current_user.id)
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


@app.get("/produce-requests/farmer/me", response_model=List[schemas.FarmerProduceRequestResponse])
def get_my_produce_requests(
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    All of the authenticated farmer's produce requests, newest first, each
    including the assigned rider and trip status once a rider has accepted
    it (null while still PENDING).
    """
    try:
        return crud.get_produce_requests_for_farmer(db, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


# ---------------------------------------------------------------------------
# Trips
# ---------------------------------------------------------------------------

# <-- NEW: MVP alias — creates a ProduceRequest, not a Trip.
# Semantically duplicates POST /produce-requests/; kept because it was
# requested. A Trip row only exists once a rider accepts via /trips/accept.
@app.post("/trips/", response_model=schemas.ProduceRequestResponse, status_code=201)
def create_trip_request(
    request: schemas.ProduceRequestCreate,
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    Create a produce pickup request for the authenticated farmer.

    NOTE: despite the URL, this creates a ProduceRequest row (status
    PENDING), not a Trip. A Trip only comes into existence when a rider
    accepts. Payload = crop_type, crate_count, weight_kg, latitude,
    longitude, dropoff_location.
    """
    try:
        return crud.create_produce_request(db, request, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


# <-- NEW: flat MVP list of the farmer's own produce requests.
@app.get("/trips/me", response_model=List[schemas.ProduceRequestResponse])
def get_my_trip_requests(
    current_user: models.User = Depends(auth.require_role("FARMER")),
    db: Session = Depends(get_db),
):
    """
    All produce requests belonging to the authenticated farmer, newest
    first. Flat response (no nested trip/rider) — the MVP view. For the
    richer feed that includes rider + trip status, use
    GET /produce-requests/farmer/me.
    """
    try:
        return crud.get_farmer_produce_requests(db, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/trips/accept", response_model=schemas.TripResponse, status_code=201)
def accept_trip(
    request_id: UUID = Query(..., description="ID of the produce request being accepted"),
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    The authenticated rider accepts a PENDING produce request, creating a
    Trip and moving the request to 'ACCEPTED'. Fails with 400 if the
    request doesn't exist or is no longer PENDING (already accepted/
    cancelled/etc).
    """
    try:
        return crud.accept_produce_request(db, request_id, current_user.id)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.patch("/trips/{trip_id}/status", response_model=schemas.TripResponse)
def update_trip_status(
    trip_id: UUID,
    body: schemas.TripStatusUpdate,
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Transition a trip to PICKED_UP, DELIVERED, or CANCELLED. Only the rider
    assigned to the trip may update it — any other authenticated rider gets
    403, which is why we fetch the trip first rather than letting
    crud.update_trip_status run unconditionally.

    Transitioning to DELIVERED also marks the underlying produce request as
    COMPLETED. Trips already in a terminal state (DELIVERED/CANCELLED)
    reject further updates with a 400.
    """
    trip = crud.get_trip_by_id(db, trip_id)
    if not trip:
        raise HTTPException(status_code=404, detail="Trip not found")
    if trip.rider_id != current_user.id:
        raise HTTPException(status_code=403, detail="You are not the rider assigned to this trip")

    try:
        result = crud.update_trip_status(db, trip_id, body.status)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))
    if not result:
        raise HTTPException(status_code=404, detail="Trip not found")
    return result


@app.get("/trips/active", response_model=schemas.ActiveTripResponse)
def get_active_trip(
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """
    Return the authenticated rider's current active trip (status ACCEPTED
    or PICKED_UP), including the pickup coordinates and crop details of the
    associated produce request. 404 if the rider has no active trip right
    now.
    """
    trip = crud.get_active_trip_for_rider(db, current_user.id)
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


# ---------------------------------------------------------------------------
# Crate Scans
# ---------------------------------------------------------------------------

@app.post("/crate-scans/", response_model=schemas.CrateScanResponse, status_code=201)
def create_crate_scan(
    scan: schemas.CrateScanCreate,
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Record a PICKUP or DELIVERY crate QR-code scan against a trip, logged
    under whichever authenticated user (farmer or rider) performed it.
    404s if the trip doesn't exist.
    """
    result = crud.create_crate_scan(db, scan, current_user.id)
    if not result:
        raise HTTPException(status_code=404, detail="Trip not found")
    return result


# ---------------------------------------------------------------------------
# Settlements
# ---------------------------------------------------------------------------

@app.post("/settlements/", response_model=schemas.SettlementResponse, status_code=201)
def create_settlement(
    settlement_in: schemas.SettlementCreate,
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Create the payout settlement for a DELIVERED trip: base fare + distance
    fare + weight surcharge. 404 if the trip doesn't exist; 400 if it isn't
    DELIVERED yet or already has a settlement.
    """
    try:
        result = crud.create_settlement(db, settlement_in)
    except (SQLAlchemyError, ValueError) as e:
        raise HTTPException(status_code=400, detail=str(e))
    if not result:
        raise HTTPException(status_code=404, detail="Trip not found")
    return result


@app.get("/settlements/me", response_model=List[schemas.SettlementResponse])
def get_my_settlements(
    current_user: models.User = Depends(auth.require_role("RIDER")),
    db: Session = Depends(get_db),
):
    """Payout history for the authenticated rider, newest first."""
    return crud.get_rider_settlements(db, current_user.id)


# ---------------------------------------------------------------------------
# Admin analytics
# ---------------------------------------------------------------------------

@app.get("/admin/stats/", response_model=schemas.AdminStatsResponse)
def get_admin_stats(
    current_user: models.User = Depends(auth.get_current_user),
    db: Session = Depends(get_db),
):
    """
    Platform-wide summary: user/farmer/rider counts, trip counts, and total
    payout volume.

    NOTE: gated only by auth.get_current_user, exactly as specified — there
    is no ADMIN role in this codebase yet (only FARMER/RIDER), so right now
    *any* logged-in farmer or rider can see platform-wide numbers, not just
    staff. If that's not intended, this needs a real admin role added to
    users.role and require_role("ADMIN") here instead.
    """
    return crud.get_admin_stats(db)


# ---------------------------------------------------------------------------
# Photo uploads
# ---------------------------------------------------------------------------

@app.post("/uploads/delivery-photo", response_model=schemas.PhotoUploadResponse, status_code=201)
async def upload_delivery_photo(
    file: UploadFile = File(...),
    current_user: models.User = Depends(auth.get_current_user),
):
    """
    Upload a delivery proof-of-photo. Saves to local static storage (see
    the UPLOAD_DIR/StaticFiles mount near the top of this file) and returns
    a URL the app can display or attach to a trip/settlement record.

    Auth wasn't specified for this endpoint in the task, but every other
    write endpoint in this file requires a caller — leaving file upload as
    the one open door would let anyone fill your disk with arbitrary
    uploads, so Depends(auth.get_current_user) is applied here too.

    The uploaded filename is never trusted for the saved path (a client
    could send `../../etc/passwd` as a filename) — the stored name is
    always a fresh UUID plus an extension this server chose, not anything
    from the request.
    """
    if file.content_type not in ALLOWED_UPLOAD_CONTENT_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported file type: {file.content_type}. Allowed: "
            f"{', '.join(sorted(ALLOWED_UPLOAD_CONTENT_TYPES))}",
        )

    contents = await file.read()
    if len(contents) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=400, detail="File too large (max 10 MB)")
    if not contents:
        raise HTTPException(status_code=400, detail="Uploaded file is empty")

    extension = ALLOWED_UPLOAD_CONTENT_TYPES[file.content_type]
    filename = f"{uuid.uuid4()}{extension}"
    destination = UPLOAD_DIR / filename

    with open(destination, "wb") as f:
        f.write(contents)

    return schemas.PhotoUploadResponse(image_url=f"/static/uploads/{filename}")