"""
Administrative Router and Business Logic for KisanRider Admin Web.
Fully protected by ADMIN role authorization.
Includes:
- Admin authentication & profile
- Real database statistics & aggregation charts
- Farmer and Rider account management (with status toggles and audit logging)
- Transport requests & Trips monitoring and safe cancellation
- Pool monitoring and intervention
- Settlement oversight and manual reconciliation
- Mandi price monitoring
- Dynamic reports & real-time CSV streaming export
- Multi-admin invitation workflow & accept token verification
- Persistent, append-only admin activity logs
"""

import csv
import hashlib
import io
import json
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Literal, Optional
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, EmailStr, Field
from sqlalchemy import and_, case, desc, func, or_, text
from sqlalchemy.orm import Session, joinedload

import auth
import config
import crud
import models
import pools.models  # registers Pool on Base.metadata
import otp_service
from database import get_db

router = APIRouter(prefix="/admin", tags=["Admin Web"])


# ---------------------------------------------------------------------------
# Audit Log Helper
# ---------------------------------------------------------------------------

def log_activity(
    db: Session,
    *,
    admin: Optional[models.User],
    action: str,
    module: str,
    description: str,
    record_id: Optional[str] = None,
    changes: Optional[Dict[str, Any]] = None,
    ip_address: Optional[str] = None,
) -> models.AdminActivityLog:
    """
    Append-only audit logging for consequential administrative operations.
    """
    audit = models.AdminActivityLog(
        id=uuid4(),
        admin_id=admin.id if admin else None,
        admin_email=admin.email if admin else "system@kisanrider.local",
        admin_name=admin.full_name if admin else "System",
        action=action,
        module=module,
        record_id=str(record_id) if record_id else None,
        description=description,
        changes=json.dumps(changes, default=str) if changes else None,
        ip_address=ip_address,
        created_at=datetime.now(timezone.utc),
    )
    db.add(audit)
    # Do not call commit here; caller commits so the action and log remain in one transaction
    return audit


# ---------------------------------------------------------------------------
# Pydantic Schemas
# ---------------------------------------------------------------------------

class AdminLoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(..., min_length=1)


class AdminUserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: UUID
    email: str
    full_name: str
    role: str
    is_active: bool
    created_at: datetime


class AdminLoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    admin: AdminUserOut


class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str = Field(..., min_length=8, max_length=128)


class UserStatusUpdateRequest(BaseModel):
    is_active: bool
    reason: str = Field(..., min_length=3, max_length=500)


class TripCancelRequest(BaseModel):
    reason: str = Field(..., min_length=3, max_length=500)


class PoolCancelRequest(BaseModel):
    reason: str = Field(..., min_length=3, max_length=500)


class SettlementReconcileRequest(BaseModel):
    payment_reference: str = Field(..., min_length=2, max_length=100)
    notes: Optional[str] = Field(None, max_length=500)


class AdminInviteRequest(BaseModel):
    email: EmailStr
    full_name: str = Field(..., min_length=2, max_length=100)


class AdminResendInviteRequest(BaseModel):
    invitation_id: UUID


class AdminAcceptInviteRequest(BaseModel):
    token: str = Field(..., min_length=10)
    password: str = Field(..., min_length=8, max_length=128)


# ---------------------------------------------------------------------------
# Authentication & Profile
# ---------------------------------------------------------------------------

@router.post("/auth/login", response_model=AdminLoginResponse)
def admin_login(
    payload: AdminLoginRequest,
    request: Request,
    db: Session = Depends(get_db),
):
    """
    Authenticate an Admin user.
    Enforces role == 'ADMIN' and is_active == True.
    """
    user = crud.get_user_by_email(db, payload.email)
    if not user or not user.password_hash:
        raise HTTPException(status_code=401, detail="Invalid admin credentials")

    if not auth.verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid admin credentials")

    if user.role != "ADMIN":
        raise HTTPException(status_code=403, detail="Access denied. User is not an Administrator.")

    if not getattr(user, "is_active", True):
        raise HTTPException(status_code=403, detail="Admin account is deactivated.")

    token = auth.create_access_token(user.id)

    # Log successful login
    client_ip = request.client.host if request.client else None
    log_activity(
        db,
        admin=user,
        action="ADMIN_LOGIN",
        module="AUTH",
        description=f"Admin {user.email} logged in successfully.",
        ip_address=client_ip,
    )
    db.commit()

    return AdminLoginResponse(
        access_token=token,
        token_type="bearer",
        admin=AdminUserOut.model_validate(user),
    )


@router.get("/auth/me", response_model=AdminUserOut)
def get_current_admin_profile(
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
):
    """
    Get profile information of the logged-in Admin.
    """
    return AdminUserOut.model_validate(current_admin)


@router.post("/auth/change-password")
def change_admin_password(
    payload: ChangePasswordRequest,
    request: Request,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Change password for currently authenticated Admin.
    Requires current password verification.
    """
    if not current_admin.password_hash or not auth.verify_password(
        payload.current_password, current_admin.password_hash
    ):
        raise HTTPException(status_code=400, detail="Current password is incorrect.")

    current_admin.password_hash = auth.hash_password(payload.new_password)

    client_ip = request.client.host if request.client else None
    log_activity(
        db,
        admin=current_admin,
        action="CHANGE_PASSWORD",
        module="AUTH",
        description=f"Admin {current_admin.email} updated account password.",
        ip_address=client_ip,
    )
    db.commit()
    return {"message": "Password updated successfully."}


# ---------------------------------------------------------------------------
# Dashboard Analytics & Statistics
# ---------------------------------------------------------------------------

@router.get("/dashboard/stats")
def get_dashboard_stats(
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Aggregated operational statistics and chart datasets calculated from real DB records.
    """
    # 1. Total counts
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
    total_requests = db.query(func.count(models.ProduceRequest.id)).scalar() or 0
    total_trips = db.query(func.count(models.Trip.id)).scalar() or 0
    completed_trips = (
        db.query(func.count(models.Trip.id))
        .filter(models.Trip.status.in_(["DELIVERED", "COMPLETED"]))
        .scalar()
        or 0
    )

    from pools.models import Pool
    active_pools = (
        db.query(func.count(Pool.id))
        .filter(Pool.status.in_(["OPEN", "DRIVER_ASSIGNED", "LOCKED", "IN_PROGRESS"]))
        .scalar()
        or 0
    )

    pending_settlements = (
        db.query(func.count(models.Settlement.id))
        .filter(models.Settlement.status == "PENDING")
        .scalar()
        or 0
    )

    total_payout_volume = (
        db.query(func.coalesce(func.sum(models.Settlement.total_payout), 0.0)).scalar()
        or 0.0
    )

    # 2. Trip status distribution
    trip_statuses_raw = (
        db.query(models.Trip.status, func.count(models.Trip.id))
        .group_by(models.Trip.status)
        .all()
    )
    trip_status_distribution = [
        {"status": s or "UNKNOWN", "count": c} for s, c in trip_statuses_raw
    ]

    # 3. Monthly transport activity (last 6 months)
    # Using SQL date truncation
    monthly_activity_raw = db.execute(text("""
        SELECT 
            TO_CHAR(created_at, 'YYYY-MM') as month,
            COUNT(*) as request_count
        FROM produce_requests
        WHERE created_at >= NOW() - INTERVAL '6 MONTH'
        GROUP BY TO_CHAR(created_at, 'YYYY-MM')
        ORDER BY month ASC;
    """)).fetchall()

    monthly_trips_raw = db.execute(text("""
        SELECT 
            TO_CHAR(created_at, 'YYYY-MM') as month,
            COUNT(*) as trip_count
        FROM trips
        WHERE created_at >= NOW() - INTERVAL '6 MONTH'
        GROUP BY TO_CHAR(created_at, 'YYYY-MM')
        ORDER BY month ASC;
    """)).fetchall()

    monthly_dict = {}
    for r in monthly_activity_raw:
        monthly_dict[r[0]] = {"month": r[0], "requests": r[1], "trips": 0}
    for t in monthly_trips_raw:
        if t[0] not in monthly_dict:
            monthly_dict[t[0]] = {"month": t[0], "requests": 0, "trips": t[1]}
        else:
            monthly_dict[t[0]]["trips"] = t[1]

    monthly_transportation = sorted(list(monthly_dict.values()), key=lambda x: x["month"])
    if not monthly_transportation:
        # Provide clean zero-state point if empty
        monthly_transportation = [{"month": datetime.now().strftime("%Y-%m"), "requests": 0, "trips": 0}]

    # 4. Farmer registration trends
    farmer_trends_raw = db.execute(text("""
        SELECT 
            TO_CHAR(created_at, 'YYYY-MM') as month,
            COUNT(*) as new_farmers
        FROM users
        WHERE role = 'FARMER' AND created_at >= NOW() - INTERVAL '6 MONTH'
        GROUP BY TO_CHAR(created_at, 'YYYY-MM')
        ORDER BY month ASC;
    """)).fetchall()
    farmer_registration_trends = [
        {"month": r[0], "farmers": r[1]} for r in farmer_trends_raw
    ]
    if not farmer_registration_trends:
        farmer_registration_trends = [{"month": datetime.now().strftime("%Y-%m"), "farmers": total_farmers}]

    # 5. District-wise transportation activity
    district_raw = db.execute(text("""
        SELECT 
            COALESCE(dropoff_district, 'Unknown') as district,
            COUNT(*) as count,
            COALESCE(SUM(weight_kg), 0) as total_weight
        FROM produce_requests
        GROUP BY dropoff_district
        ORDER BY count DESC
        LIMIT 8;
    """)).fetchall()
    district_activity = [
        {"district": r[0], "count": r[1], "weight_kg": float(r[2])} for r in district_raw
    ]

    # 6. Recent Requests
    recent_requests_rows = (
        db.query(models.ProduceRequest)
        .order_by(models.ProduceRequest.created_at.desc())
        .limit(5)
        .all()
    )
    recent_requests = [
        {
            "id": str(r.id),
            "crop_type": r.crop_type,
            "weight_kg": float(r.weight_kg or 0),
            "pickup_address": r.pickup_address or "Farm Gate",
            "dropoff_mandi_name": r.dropoff_mandi_name or r.dropoff_district or "Mandi",
            "status": r.status,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        }
        for r in recent_requests_rows
    ]

    # 7. Recent Trips
    recent_trips_rows = (
        db.query(models.Trip)
        .order_by(models.Trip.created_at.desc())
        .limit(5)
        .all()
    )
    recent_trips = [
        {
            "id": str(t.id),
            "status": t.status,
            "pickup_address": t.pickup_address or "Origin",
            "created_at": t.created_at.isoformat() if t.created_at else None,
            "completed_at": t.completed_at.isoformat() if t.completed_at else None,
        }
        for t in recent_trips_rows
    ]

    # 8. Latest Farmer Registrations
    latest_farmers_rows = (
        db.query(models.User)
        .filter(models.User.role == "FARMER")
        .order_by(models.User.created_at.desc())
        .limit(5)
        .all()
    )
    latest_farmers = [
        {
            "id": str(f.id),
            "full_name": f.full_name,
            "district": f.district or "Karnataka",
            "phone_number": f.phone_number or f.phone,
            "is_active": getattr(f, "is_active", True),
            "created_at": f.created_at.isoformat() if f.created_at else None,
        }
        for f in latest_farmers_rows
    ]

    return {
        "cards": {
            "total_farmers": total_farmers,
            "total_riders": total_riders,
            "total_requests": total_requests,
            "total_trips": total_trips,
            "completed_trips": completed_trips,
            "active_pools": active_pools,
            "pending_settlements": pending_settlements,
            "total_payout_volume": round(float(total_payout_volume), 2),
        },
        "charts": {
            "monthly_transportation": monthly_transportation,
            "trip_status_distribution": trip_status_distribution,
            "farmer_registration_trends": farmer_registration_trends,
            "district_activity": district_activity,
        },
        "recent": {
            "requests": recent_requests,
            "trips": recent_trips,
            "farmers": latest_farmers,
        },
    }


# ---------------------------------------------------------------------------
# Farmer Management
# ---------------------------------------------------------------------------

@router.get("/farmers")
def list_farmers(
    search: Optional[str] = None,
    district: Optional[str] = None,
    status_filter: Optional[str] = Query("ALL", pattern="^(ALL|ACTIVE|SUSPENDED)$"),
    page: int = Query(1, ge=1),
    limit: int = Query(10, ge=1, le=100),
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    List farmers with search, district and status filtering, and server pagination.
    """
    query = db.query(models.User).filter(models.User.role == "FARMER")

    if search and search.strip():
        term = f"%{search.strip().lower()}%"
        query = query.filter(
            or_(
                func.lower(models.User.full_name).like(term),
                func.lower(models.User.email).like(term),
                models.User.phone_number.like(term),
                models.User.phone.like(term),
                func.lower(models.User.taluk_village).like(term),
            )
        )

    if district and district.strip() and district.lower() not in ("all", "all karnataka"):
        query = query.filter(func.lower(models.User.district) == district.strip().lower())

    if status_filter == "ACTIVE":
        query = query.filter(models.User.is_active == True)
    elif status_filter == "SUSPENDED":
        query = query.filter(models.User.is_active == False)

    total_count = query.count()
    offset = (page - 1) * limit
    farmers = (
        query.order_by(models.User.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )

    items = []
    for f in farmers:
        req_count = db.query(func.count(models.ProduceRequest.id)).filter(models.ProduceRequest.farmer_id == f.id).scalar() or 0
        items.append({
            "id": str(f.id),
            "full_name": f.full_name,
            "email": f.email,
            "phone_number": f.phone_number or f.phone,
            "district": f.district or "Karnataka",
            "taluk_village": f.taluk_village,
            "farm_size_acres": f.farm_size_acres,
            "primary_crops": f.primary_crops,
            "is_active": getattr(f, "is_active", True),
            "created_at": f.created_at.isoformat() if f.created_at else None,
            "total_requests": req_count,
        })

    return {
        "items": items,
        "total": total_count,
        "page": page,
        "limit": limit,
        "total_pages": (total_count + limit - 1) // limit if total_count > 0 else 1,
    }


@router.get("/farmers/{farmer_id}")
def get_farmer_details(
    farmer_id: UUID,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Detailed farmer profile including transportation history, saved addresses, and settlements.
    """
    farmer = db.query(models.User).filter(models.User.id == farmer_id, models.User.role == "FARMER").first()
    if not farmer:
        raise HTTPException(status_code=404, detail="Farmer not found.")

    # 1. Saved addresses
    addresses = (
        db.query(models.SavedAddress)
        .filter(models.SavedAddress.farmer_id == farmer_id)
        .order_by(models.SavedAddress.created_at.desc())
        .all()
    )

    # 2. Produce requests
    requests = (
        db.query(models.ProduceRequest)
        .filter(models.ProduceRequest.farmer_id == farmer_id)
        .order_by(models.ProduceRequest.created_at.desc())
        .limit(20)
        .all()
    )

    # 3. Settlements
    settlements = (
        db.query(models.Settlement)
        .filter(models.Settlement.farmer_id == farmer_id)
        .order_by(models.Settlement.created_at.desc())
        .limit(20)
        .all()
    )

    return {
        "farmer": {
            "id": str(farmer.id),
            "full_name": farmer.full_name,
            "email": farmer.email,
            "phone_number": farmer.phone_number or farmer.phone,
            "district": farmer.district or "Karnataka",
            "taluk_village": farmer.taluk_village,
            "farm_size_acres": farmer.farm_size_acres,
            "primary_crops": farmer.primary_crops,
            "farm_address": farmer.farm_address,
            "landmark": farmer.landmark,
            "is_active": getattr(farmer, "is_active", True),
            "is_verified": farmer.is_verified,
            "bank_name": farmer.bank_name,
            "account_number": farmer.account_number,
            "ifsc_code": farmer.ifsc_code,
            "upi_id": farmer.upi_id,
            "preferred_language": farmer.preferred_language,
            "created_at": farmer.created_at.isoformat() if farmer.created_at else None,
        },
        "saved_addresses": [
            {
                "id": str(a.id),
                "title": a.title,
                "address_text": a.address_text,
                "landmark": a.landmark,
                "created_at": a.created_at.isoformat() if a.created_at else None,
            }
            for a in addresses
        ],
        "requests": [
            {
                "id": str(r.id),
                "crop_type": r.crop_type,
                "weight_kg": float(r.weight_kg or 0),
                "pickup_address": r.pickup_address,
                "dropoff_mandi_name": r.dropoff_mandi_name or r.dropoff_district,
                "status": r.status,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in requests
        ],
        "settlements": [
            {
                "id": str(s.id),
                "trip_id": str(s.trip_id),
                "crop_name": s.crop_name,
                "gross_amount": s.gross_amount,
                "platform_fee": s.platform_fee,
                "net_payout": s.net_payout,
                "total_payout": s.total_payout,
                "status": s.status,
                "created_at": s.created_at.isoformat() if s.created_at else None,
            }
            for s in settlements
        ],
    }


@router.patch("/farmers/{farmer_id}/status")
def update_farmer_status(
    farmer_id: UUID,
    payload: UserStatusUpdateRequest,
    request: Request,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Suspend or reactivate a farmer account.
    Records consequential action in persistent Admin Activity Logs.
    """
    farmer = db.query(models.User).filter(models.User.id == farmer_id, models.User.role == "FARMER").first()
    if not farmer:
        raise HTTPException(status_code=404, detail="Farmer not found.")

    old_status = getattr(farmer, "is_active", True)
    farmer.is_active = payload.is_active

    action = "REACTIVATE_FARMER" if payload.is_active else "SUSPEND_FARMER"
    desc = f"Admin {current_admin.email} set Farmer {farmer.full_name} status to {'ACTIVE' if payload.is_active else 'SUSPENDED'}. Reason: {payload.reason}"
    client_ip = request.client.host if request.client else None

    log_activity(
        db,
        admin=current_admin,
        action=action,
        module="FARMERS",
        record_id=str(farmer.id),
        description=desc,
        changes={"old_is_active": old_status, "new_is_active": payload.is_active, "reason": payload.reason},
        ip_address=client_ip,
    )
    db.commit()

    return {"message": "Farmer status updated successfully.", "is_active": farmer.is_active}


# ---------------------------------------------------------------------------
# Rider Management
# ---------------------------------------------------------------------------

@router.get("/riders")
def list_riders(
    search: Optional[str] = None,
    duty_status: Optional[str] = Query("ALL", pattern="^(ALL|ON_DUTY|OFF_DUTY)$"),
    status_filter: Optional[str] = Query("ALL", pattern="^(ALL|ACTIVE|SUSPENDED)$"),
    page: int = Query(1, ge=1),
    limit: int = Query(10, ge=1, le=100),
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    List riders with duty status, search, and pagination.
    """
    query = db.query(models.User).filter(models.User.role == "RIDER")

    if search and search.strip():
        term = f"%{search.strip().lower()}%"
        query = query.filter(
            or_(
                func.lower(models.User.full_name).like(term),
                func.lower(models.User.email).like(term),
                models.User.phone_number.like(term),
                models.User.phone.like(term),
                func.lower(models.User.vehicle_number).like(term),
                func.lower(models.User.license_number).like(term),
            )
        )

    if duty_status == "ON_DUTY":
        query = query.filter(models.User.is_on_duty == True)
    elif duty_status == "OFF_DUTY":
        query = query.filter(models.User.is_on_duty == False)

    if status_filter == "ACTIVE":
        query = query.filter(models.User.is_active == True)
    elif status_filter == "SUSPENDED":
        query = query.filter(models.User.is_active == False)

    total_count = query.count()
    offset = (page - 1) * limit
    riders = (
        query.order_by(models.User.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )

    items = []
    for r in riders:
        completed_trips = (
            db.query(func.count(models.Trip.id))
            .filter(models.Trip.rider_id == r.id, models.Trip.status.in_(["DELIVERED", "COMPLETED"]))
            .scalar()
            or 0
        )
        earnings = (
            db.query(func.coalesce(func.sum(models.Settlement.rider_fare), 0.0))
            .filter(models.Settlement.rider_id == r.id)
            .scalar()
            or 0.0
        )
        items.append({
            "id": str(r.id),
            "full_name": r.full_name,
            "email": r.email,
            "phone_number": r.phone_number or r.phone,
            "vehicle_type": r.vehicle_type or "Pickup",
            "vehicle_number": r.vehicle_number,
            "payload_capacity_kg": r.payload_capacity_kg,
            "operating_routes": r.operating_routes,
            "is_on_duty": r.is_on_duty,
            "is_active": getattr(r, "is_active", True),
            "created_at": r.created_at.isoformat() if r.created_at else None,
            "completed_trips": completed_trips,
            "total_earnings": round(float(earnings), 2),
        })

    return {
        "items": items,
        "total": total_count,
        "page": page,
        "limit": limit,
        "total_pages": (total_count + limit - 1) // limit if total_count > 0 else 1,
    }


@router.get("/riders/{rider_id}")
def get_rider_details(
    rider_id: UUID,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Detailed Rider profile including vehicle, license, trip history, and settlements.
    """
    rider = db.query(models.User).filter(models.User.id == rider_id, models.User.role == "RIDER").first()
    if not rider:
        raise HTTPException(status_code=404, detail="Rider not found.")

    trips = (
        db.query(models.Trip)
        .filter(models.Trip.rider_id == rider_id)
        .order_by(models.Trip.created_at.desc())
        .limit(20)
        .all()
    )

    settlements = (
        db.query(models.Settlement)
        .filter(models.Settlement.rider_id == rider_id)
        .order_by(models.Settlement.created_at.desc())
        .limit(20)
        .all()
    )

    return {
        "rider": {
            "id": str(rider.id),
            "full_name": rider.full_name,
            "email": rider.email,
            "phone_number": rider.phone_number or rider.phone,
            "vehicle_type": rider.vehicle_type,
            "vehicle_number": rider.vehicle_number,
            "payload_capacity_kg": rider.payload_capacity_kg,
            "operating_routes": rider.operating_routes,
            "license_number": rider.license_number,
            "is_on_duty": rider.is_on_duty,
            "is_active": getattr(rider, "is_active", True),
            "is_verified": rider.is_verified,
            "bank_name": rider.bank_name,
            "account_number": rider.account_number,
            "ifsc_code": rider.ifsc_code,
            "upi_id": rider.upi_id,
            "created_at": rider.created_at.isoformat() if rider.created_at else None,
        },
        "trips": [
            {
                "id": str(t.id),
                "status": t.status,
                "pickup_address": t.pickup_address,
                "created_at": t.created_at.isoformat() if t.created_at else None,
                "completed_at": t.completed_at.isoformat() if t.completed_at else None,
            }
            for t in trips
        ],
        "settlements": [
            {
                "id": str(s.id),
                "trip_id": str(s.trip_id),
                "crop_name": s.crop_name,
                "rider_fare": s.rider_fare,
                "total_payout": s.total_payout,
                "status": s.status,
                "created_at": s.created_at.isoformat() if s.created_at else None,
            }
            for s in settlements
        ],
    }


@router.patch("/riders/{rider_id}/status")
def update_rider_status(
    rider_id: UUID,
    payload: UserStatusUpdateRequest,
    request: Request,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Suspend or reactivate a Rider account.
    """
    rider = db.query(models.User).filter(models.User.id == rider_id, models.User.role == "RIDER").first()
    if not rider:
        raise HTTPException(status_code=404, detail="Rider not found.")

    old_status = getattr(rider, "is_active", True)
    rider.is_active = payload.is_active

    action = "REACTIVATE_RIDER" if payload.is_active else "SUSPEND_RIDER"
    desc = f"Admin {current_admin.email} set Rider {rider.full_name} status to {'ACTIVE' if payload.is_active else 'SUSPENDED'}. Reason: {payload.reason}"
    client_ip = request.client.host if request.client else None

    log_activity(
        db,
        admin=current_admin,
        action=action,
        module="RIDERS",
        record_id=str(rider.id),
        description=desc,
        changes={"old_is_active": old_status, "new_is_active": payload.is_active, "reason": payload.reason},
        ip_address=client_ip,
    )
    db.commit()

    return {"message": "Rider status updated successfully.", "is_active": rider.is_active}


# ---------------------------------------------------------------------------
# Transport Requests
# ---------------------------------------------------------------------------

@router.get("/requests")
def list_transport_requests(
    search: Optional[str] = None,
    crop_type: Optional[str] = None,
    district: Optional[str] = None,
    status_filter: Optional[str] = None,
    page: int = Query(1, ge=1),
    limit: int = Query(10, ge=1, le=100),
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    List produce transportation requests with search and filters.
    """
    query = db.query(models.ProduceRequest).options(joinedload(models.ProduceRequest.farmer))

    if search and search.strip():
        term = f"%{search.strip().lower()}%"
        query = query.join(models.ProduceRequest.farmer).filter(
            or_(
                func.lower(models.ProduceRequest.crop_type).like(term),
                func.lower(models.ProduceRequest.pickup_address).like(term),
                func.lower(models.ProduceRequest.dropoff_mandi_name).like(term),
                func.lower(models.User.full_name).like(term),
            )
        )

    if crop_type and crop_type.strip() and crop_type.lower() != "all":
        query = query.filter(func.lower(models.ProduceRequest.crop_type) == crop_type.strip().lower())

    if district and district.strip() and district.lower() not in ("all", "all karnataka"):
        query = query.filter(func.lower(models.ProduceRequest.dropoff_district) == district.strip().lower())

    if status_filter and status_filter.strip() and status_filter.lower() != "all":
        query = query.filter(models.ProduceRequest.status == status_filter.strip().upper())

    total_count = query.count()
    offset = (page - 1) * limit
    requests_rows = (
        query.order_by(models.ProduceRequest.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )

    items = []
    for r in requests_rows:
        # Check if there is an assigned rider via trip
        trip = db.query(models.Trip).options(joinedload(models.Trip.rider)).filter(models.Trip.produce_request_id == r.id).first()
        rider_name = trip.rider.full_name if (trip and trip.rider) else None

        items.append({
            "id": str(r.id),
            "farmer_id": str(r.farmer_id),
            "farmer_name": r.farmer.full_name if r.farmer else "Unknown",
            "farmer_phone": r.farmer.phone_number or r.farmer.phone if r.farmer else None,
            "crop_type": r.crop_type,
            "weight_kg": float(r.weight_kg or 0),
            "pickup_address": r.pickup_address or "Farm Gate",
            "pickup_landmark": r.pickup_landmark,
            "dropoff_district": r.dropoff_district,
            "dropoff_mandi_name": r.dropoff_mandi_name or r.dropoff_location or "APMC Yard",
            "dropoff_stall_number": r.dropoff_stall_number,
            "status": r.status,
            "cancellation_reason": r.cancellation_reason,
            "created_at": r.created_at.isoformat() if r.created_at else None,
            "assigned_rider": rider_name,
            "trip_id": str(trip.id) if trip else None,
        })

    return {
        "items": items,
        "total": total_count,
        "page": page,
        "limit": limit,
        "total_pages": (total_count + limit - 1) // limit if total_count > 0 else 1,
    }


@router.get("/requests/{request_id}")
def get_transport_request_detail(
    request_id: UUID,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Get detailed transport request with linked farmer, trip, and rider.
    """
    r = (
        db.query(models.ProduceRequest)
        .options(joinedload(models.ProduceRequest.farmer))
        .filter(models.ProduceRequest.id == request_id)
        .first()
    )
    if not r:
        raise HTTPException(status_code=404, detail="Transport request not found.")

    trip = (
        db.query(models.Trip)
        .options(joinedload(models.Trip.rider))
        .filter(models.Trip.produce_request_id == r.id)
        .first()
    )

    return {
        "request": {
            "id": str(r.id),
            "crop_type": r.crop_type,
            "weight_kg": float(r.weight_kg or 0),
            "pickup_address": r.pickup_address,
            "pickup_landmark": r.pickup_landmark,
            "pickup_otp": r.pickup_otp,
            "dropoff_district": r.dropoff_district,
            "dropoff_mandi_name": r.dropoff_mandi_name,
            "dropoff_stall_number": r.dropoff_stall_number,
            "dropoff_location": r.dropoff_location,
            "status": r.status,
            "cancellation_reason": r.cancellation_reason,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        },
        "farmer": {
            "id": str(r.farmer.id) if r.farmer else None,
            "full_name": r.farmer.full_name if r.farmer else "Unknown",
            "phone": r.farmer.phone_number or r.farmer.phone if r.farmer else None,
            "district": r.farmer.district if r.farmer else None,
        },
        "trip": {
            "id": str(trip.id) if trip else None,
            "status": trip.status if trip else None,
            "created_at": trip.created_at.isoformat() if trip and trip.created_at else None,
            "rider_name": trip.rider.full_name if trip and trip.rider else None,
            "rider_phone": trip.rider.phone_number or trip.rider.phone if trip and trip.rider else None,
        } if trip else None,
    }


# ---------------------------------------------------------------------------
# Trips
# ---------------------------------------------------------------------------

@router.get("/trips")
def list_trips(
    search: Optional[str] = None,
    status_filter: Optional[str] = None,
    page: int = Query(1, ge=1),
    limit: int = Query(10, ge=1, le=100),
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    List all trips with rider, farmer, pool associations, and pagination.
    """
    query = (
        db.query(models.Trip)
        .options(
            joinedload(models.Trip.rider),
            joinedload(models.Trip.produce_request).joinedload(models.ProduceRequest.farmer),
        )
    )

    if status_filter and status_filter.strip() and status_filter.lower() != "all":
        query = query.filter(models.Trip.status == status_filter.strip().upper())

    if search and search.strip():
        term = f"%{search.strip().lower()}%"
        query = query.filter(
            or_(
                func.lower(models.Trip.pickup_address).like(term),
                func.cast(models.Trip.id, text).like(term),
            )
        )

    total_count = query.count()
    offset = (page - 1) * limit
    trips_rows = (
        query.order_by(models.Trip.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )

    items = []
    for t in trips_rows:
        pr = t.produce_request
        farmer = pr.farmer if pr else None
        items.append({
            "id": str(t.id),
            "rider_id": str(t.rider_id),
            "rider_name": t.rider.full_name if t.rider else "Unassigned",
            "rider_phone": t.rider.phone_number or t.rider.phone if t.rider else None,
            "farmer_name": farmer.full_name if farmer else "Unknown",
            "farmer_phone": farmer.phone_number or farmer.phone if farmer else None,
            "crop_type": pr.crop_type if pr else None,
            "weight_kg": float(pr.weight_kg or 0) if pr else 0,
            "pool_id": str(t.pool_id) if t.pool_id else None,
            "pickup_address": t.pickup_address or (pr.pickup_address if pr else "Farm Gate"),
            "destination": pr.dropoff_mandi_name or (pr.dropoff_district if pr else "APMC Yard"),
            "status": t.status,
            "created_at": t.created_at.isoformat() if t.created_at else None,
            "completed_at": t.completed_at.isoformat() if t.completed_at else None,
        })

    return {
        "items": items,
        "total": total_count,
        "page": page,
        "limit": limit,
        "total_pages": (total_count + limit - 1) // limit if total_count > 0 else 1,
    }


@router.get("/trips/{trip_id}")
def get_trip_detail(
    trip_id: UUID,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Detailed trip view with crate scans, settlement, and delivery photo proof.
    """
    trip = (
        db.query(models.Trip)
        .options(
            joinedload(models.Trip.rider),
            joinedload(models.Trip.produce_request).joinedload(models.ProduceRequest.farmer),
            joinedload(models.Trip.crate_scans),
            joinedload(models.Trip.settlement),
        )
        .filter(models.Trip.id == trip_id)
        .first()
    )
    if not trip:
        raise HTTPException(status_code=404, detail="Trip not found.")

    pr = trip.produce_request
    farmer = pr.farmer if pr else None
    settlement = trip.settlement

    return {
        "trip": {
            "id": str(trip.id),
            "status": trip.status,
            "pickup_address": trip.pickup_address or (pr.pickup_address if pr else None),
            "pickup_landmark": trip.pickup_landmark or (pr.pickup_landmark if pr else None),
            "created_at": trip.created_at.isoformat() if trip.created_at else None,
            "completed_at": trip.completed_at.isoformat() if trip.completed_at else None,
            "pool_id": str(trip.pool_id) if trip.pool_id else None,
        },
        "rider": {
            "id": str(trip.rider.id) if trip.rider else None,
            "full_name": trip.rider.full_name if trip.rider else "Unassigned",
            "phone": trip.rider.phone_number or trip.rider.phone if trip.rider else None,
            "vehicle_type": trip.rider.vehicle_type if trip.rider else None,
            "vehicle_number": trip.rider.vehicle_number if trip.rider else None,
        },
        "farmer": {
            "id": str(farmer.id) if farmer else None,
            "full_name": farmer.full_name if farmer else "Unknown",
            "phone": farmer.phone_number or farmer.phone if farmer else None,
            "district": farmer.district if farmer else None,
        },
        "produce_request": {
            "id": str(pr.id) if pr else None,
            "crop_type": pr.crop_type if pr else None,
            "weight_kg": float(pr.weight_kg or 0) if pr else 0,
            "dropoff_mandi_name": pr.dropoff_mandi_name if pr else None,
            "dropoff_district": pr.dropoff_district if pr else None,
            "pickup_otp": pr.pickup_otp if pr else None,
        } if pr else None,
        "crate_scans": [
            {
                "id": str(cs.id),
                "scan_type": cs.scan_type,
                "qr_code": cs.qr_code,
                "scanned_at": cs.scanned_at.isoformat() if cs.scanned_at else None,
            }
            for cs in (trip.crate_scans or [])
        ],
        "settlement": {
            "id": str(settlement.id) if settlement else None,
            "gross_amount": settlement.gross_amount if settlement else None,
            "rider_fare": settlement.rider_fare if settlement else None,
            "platform_fee": settlement.platform_fee if settlement else None,
            "net_payout": settlement.net_payout if settlement else None,
            "status": settlement.status if settlement else None,
        } if settlement else None,
    }


@router.post("/trips/{trip_id}/cancel")
def cancel_trip_admin(
    trip_id: UUID,
    payload: TripCancelRequest,
    request: Request,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Administrative trip cancellation.
    Disallows cancelling completed or already cancelled trips.
    Requires reason, records in audit log.
    """
    trip = db.query(models.Trip).filter(models.Trip.id == trip_id).first()
    if not trip:
        raise HTTPException(status_code=404, detail="Trip not found.")

    if trip.status in ("DELIVERED", "COMPLETED"):
        raise HTTPException(status_code=400, detail="Cannot cancel a delivered / completed trip.")
    if trip.status == "CANCELLED":
        raise HTTPException(status_code=400, detail="Trip is already cancelled.")

    old_status = trip.status
    trip.status = "CANCELLED"

    # Also set linked produce request status to CANCELLED with reason
    pr = db.query(models.ProduceRequest).filter(models.ProduceRequest.id == trip.produce_request_id).first()
    if pr:
        pr.status = "CANCELLED"
        pr.cancellation_reason = f"Cancelled by Admin: {payload.reason}"

    client_ip = request.client.host if request.client else None
    desc = f"Admin {current_admin.email} cancelled Trip {trip.id}. Reason: {payload.reason}"
    log_activity(
        db,
        admin=current_admin,
        action="CANCEL_TRIP",
        module="TRIPS",
        record_id=str(trip.id),
        description=desc,
        changes={"old_status": old_status, "new_status": "CANCELLED", "reason": payload.reason},
        ip_address=client_ip,
    )
    db.commit()

    return {"message": "Trip cancelled successfully.", "trip_id": str(trip.id)}


# ---------------------------------------------------------------------------
# Farmer Pool Management
# ---------------------------------------------------------------------------

@router.get("/pools")
def list_farmer_pools(
    crop_type: Optional[str] = None,
    district: Optional[str] = None,
    status_filter: Optional[str] = None,
    page: int = Query(1, ge=1),
    limit: int = Query(10, ge=1, le=100),
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    List Farmer Pools from existing Pool model with member counts and current status.
    """
    from pools.models import Pool, PoolMember

    query = db.query(Pool)

    if crop_type and crop_type.strip() and crop_type.lower() != "all":
        query = query.filter(func.lower(Pool.crop_type) == crop_type.strip().lower())

    if district and district.strip() and district.lower() not in ("all", "all karnataka"):
        query = query.filter(func.lower(Pool.dropoff_district) == district.strip().lower())

    if status_filter and status_filter.strip() and status_filter.lower() != "all":
        query = query.filter(Pool.status == status_filter.strip().upper())

    total_count = query.count()
    offset = (page - 1) * limit
    pools_rows = (
        query.order_by(Pool.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )

    items = []
    for p in pools_rows:
        creator = db.query(models.User).filter(models.User.id == p.creator_id).first()
        member_count = db.query(func.count(PoolMember.id)).filter(PoolMember.pool_id == p.id).scalar() or 0

        # Assigned rider via trip
        trip = db.query(models.Trip).options(joinedload(models.Trip.rider)).filter(models.Trip.pool_id == p.id).first()
        rider_name = trip.rider.full_name if (trip and trip.rider) else None

        items.append({
            "id": str(p.id),
            "creator_id": str(p.creator_id),
            "creator_name": creator.full_name if creator else "Unknown",
            "creator_phone": creator.phone_number or creator.phone if creator else None,
            "crop_type": p.crop_type,
            "current_qty": p.current_qty,
            "min_qty": p.min_qty,
            "max_qty": p.max_qty,
            "members_count": member_count,
            "dropoff_district": p.dropoff_district,
            "dropoff_mandi_name": p.dropoff_mandi_name,
            "pickup_window_start": p.pickup_window_start.isoformat() if p.pickup_window_start else None,
            "pickup_window_end": p.pickup_window_end.isoformat() if p.pickup_window_end else None,
            "status": p.status,
            "assigned_rider": rider_name,
            "created_at": p.created_at.isoformat() if p.created_at else None,
        })

    return {
        "items": items,
        "total": total_count,
        "page": page,
        "limit": limit,
        "total_pages": (total_count + limit - 1) // limit if total_count > 0 else 1,
    }


@router.get("/pools/{pool_id}")
def get_farmer_pool_detail(
    pool_id: UUID,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Detailed Farmer Pool view including participating farmers, stops, and linked trips.
    """
    from pools.models import Pool, PoolMember, PoolStop

    pool = db.query(Pool).filter(Pool.id == pool_id).first()
    if not pool:
        raise HTTPException(status_code=404, detail="Farmer Pool not found.")

    creator = db.query(models.User).filter(models.User.id == pool.creator_id).first()

    members_raw = db.query(PoolMember).filter(PoolMember.pool_id == pool.id).all()
    members = []
    for m in members_raw:
        farmer = db.query(models.User).filter(models.User.id == m.farmer_id).first()
        members.append({
            "id": str(m.id),
            "farmer_id": str(m.farmer_id),
            "farmer_name": farmer.full_name if farmer else "Farmer",
            "farmer_phone": farmer.phone_number or farmer.phone if farmer else None,
            "weight_kg": m.weight_kg,
            "status": m.status,
            "contribution_to_total": m.contribution_to_total,
            "requested_at": m.requested_at.isoformat() if m.requested_at else None,
        })

    stops_raw = db.query(PoolStop).filter(PoolStop.pool_id == pool.id).order_by(PoolStop.sequence.asc()).all()
    stops = []
    for s in stops_raw:
        pr = db.query(models.ProduceRequest).filter(models.ProduceRequest.id == s.produce_request_id).first()
        stops.append({
            "id": str(s.id),
            "sequence": s.sequence,
            "status": s.status,
            "pickup_address": pr.pickup_address if pr else "Pickup Location",
            "weight_kg": float(pr.weight_kg or 0) if pr else 0,
            "arrived_at": s.arrived_at.isoformat() if s.arrived_at else None,
            "picked_up_at": s.picked_up_at.isoformat() if s.picked_up_at else None,
        })

    trips_raw = db.query(models.Trip).options(joinedload(models.Trip.rider)).filter(models.Trip.pool_id == pool.id).all()
    trips = [
        {
            "id": str(t.id),
            "rider_name": t.rider.full_name if t.rider else "Unassigned",
            "rider_phone": t.rider.phone_number or t.rider.phone if t.rider else None,
            "status": t.status,
            "created_at": t.created_at.isoformat() if t.created_at else None,
        }
        for t in trips_raw
    ]

    return {
        "pool": {
            "id": str(pool.id),
            "creator_id": str(pool.creator_id),
            "creator_name": creator.full_name if creator else "Unknown",
            "crop_type": pool.crop_type,
            "current_qty": pool.current_qty,
            "min_qty": pool.min_qty,
            "max_qty": pool.max_qty,
            "dropoff_district": pool.dropoff_district,
            "dropoff_mandi_name": pool.dropoff_mandi_name,
            "dropoff_stall_number": pool.dropoff_stall_number,
            "pickup_window_start": pool.pickup_window_start.isoformat() if pool.pickup_window_start else None,
            "pickup_window_end": pool.pickup_window_end.isoformat() if pool.pickup_window_end else None,
            "status": pool.status,
            "auto_approve": pool.auto_approve,
            "notes": pool.notes,
            "created_at": pool.created_at.isoformat() if pool.created_at else None,
        },
        "members": members,
        "stops": stops,
        "trips": trips,
    }


@router.post("/pools/{pool_id}/cancel")
def cancel_pool_admin(
    pool_id: UUID,
    payload: PoolCancelRequest,
    request: Request,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Administrative pool cancellation with audit logging.
    """
    from pools.models import Pool

    pool = db.query(Pool).filter(Pool.id == pool_id).first()
    if not pool:
        raise HTTPException(status_code=404, detail="Pool not found.")

    if pool.status in ("COMPLETED", "CANCELLED"):
        raise HTTPException(status_code=400, detail=f"Cannot cancel pool in {pool.status} status.")

    old_status = pool.status
    pool.status = "CANCELLED"
    pool.notes = f"{pool.notes or ''} [Cancelled by Admin: {payload.reason}]".strip()

    client_ip = request.client.host if request.client else None
    desc = f"Admin {current_admin.email} cancelled Pool {pool.id}. Reason: {payload.reason}"
    log_activity(
        db,
        admin=current_admin,
        action="CANCEL_POOL",
        module="POOLS",
        record_id=str(pool.id),
        description=desc,
        changes={"old_status": old_status, "new_status": "CANCELLED", "reason": payload.reason},
        ip_address=client_ip,
    )
    db.commit()

    return {"message": "Farmer Pool cancelled successfully.", "pool_id": str(pool.id)}


# ---------------------------------------------------------------------------
# Settlement Management
# ---------------------------------------------------------------------------

@router.get("/settlements")
def list_settlements(
    status_filter: Optional[str] = None,
    farmer_id: Optional[UUID] = None,
    rider_id: Optional[UUID] = None,
    page: int = Query(1, ge=1),
    limit: int = Query(10, ge=1, le=100),
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    List all settlements with calculated financial values, status, and linked parties.
    """
    query = (
        db.query(models.Settlement)
        .options(
            joinedload(models.Settlement.trip),
        )
    )

    if status_filter and status_filter.strip() and status_filter.lower() != "all":
        query = query.filter(models.Settlement.status == status_filter.strip().upper())

    if farmer_id:
        query = query.filter(models.Settlement.farmer_id == farmer_id)

    if rider_id:
        query = query.filter(models.Settlement.rider_id == rider_id)

    total_count = query.count()
    offset = (page - 1) * limit
    settlements_rows = (
        query.order_by(models.Settlement.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )

    items = []
    for s in settlements_rows:
        farmer = db.query(models.User).filter(models.User.id == s.farmer_id).first() if s.farmer_id else None
        rider = db.query(models.User).filter(models.User.id == s.rider_id).first() if s.rider_id else None

        items.append({
            "id": str(s.id),
            "trip_id": str(s.trip_id),
            "farmer_name": farmer.full_name if farmer else "Farmer",
            "rider_name": rider.full_name if rider else "Rider",
            "crop_name": s.crop_name or "Produce",
            "quantity_kg": s.quantity_kg,
            "gross_amount": s.gross_amount or 0.0,
            "platform_fee": s.platform_fee or 0.0,
            "rider_fare": s.rider_fare or 0.0,
            "net_payout": s.net_payout or s.total_payout,
            "total_payout": s.total_payout,
            "status": s.status,
            "created_at": s.created_at.isoformat() if s.created_at else None,
        })

    return {
        "items": items,
        "total": total_count,
        "page": page,
        "limit": limit,
        "total_pages": (total_count + limit - 1) // limit if total_count > 0 else 1,
    }


@router.get("/settlements/{settlement_id}")
def get_settlement_detail(
    settlement_id: UUID,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Detailed settlement breakdown.
    """
    s = db.query(models.Settlement).filter(models.Settlement.id == settlement_id).first()
    if not s:
        raise HTTPException(status_code=404, detail="Settlement not found.")

    farmer = db.query(models.User).filter(models.User.id == s.farmer_id).first() if s.farmer_id else None
    rider = db.query(models.User).filter(models.User.id == s.rider_id).first() if s.rider_id else None
    trip = db.query(models.Trip).filter(models.Trip.id == s.trip_id).first() if s.trip_id else None

    return {
        "settlement": {
            "id": str(s.id),
            "trip_id": str(s.trip_id),
            "crop_name": s.crop_name,
            "quantity_kg": s.quantity_kg,
            "base_fare": s.base_fare,
            "distance_fare": s.distance_fare,
            "weight_surcharge": s.weight_surcharge,
            "gross_amount": s.gross_amount,
            "rider_fare": s.rider_fare,
            "platform_fee": s.platform_fee,
            "net_payout": s.net_payout,
            "total_payout": s.total_payout,
            "status": s.status,
            "created_at": s.created_at.isoformat() if s.created_at else None,
        },
        "farmer": {
            "id": str(farmer.id) if farmer else None,
            "full_name": farmer.full_name if farmer else None,
            "bank_name": farmer.bank_name if farmer else None,
            "account_number": farmer.account_number if farmer else None,
            "ifsc_code": farmer.ifsc_code if farmer else None,
            "upi_id": farmer.upi_id if farmer else None,
        },
        "rider": {
            "id": str(rider.id) if rider else None,
            "full_name": rider.full_name if rider else None,
            "bank_name": rider.bank_name if rider else None,
            "account_number": rider.account_number if rider else None,
            "ifsc_code": rider.ifsc_code if rider else None,
            "upi_id": rider.upi_id if rider else None,
        },
        "trip": {
            "id": str(trip.id) if trip else None,
            "status": trip.status if trip else None,
            "pickup_address": trip.pickup_address if trip else None,
        },
    }


@router.patch("/settlements/{settlement_id}/reconcile")
def reconcile_settlement_status(
    settlement_id: UUID,
    payload: SettlementReconcileRequest,
    request: Request,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Reconcile a pending settlement to PAID status with external payment reference and audit note.
    Does not initiate fake bank transfer. Records external reconciliation transaction.
    """
    s = db.query(models.Settlement).filter(models.Settlement.id == settlement_id).first()
    if not s:
        raise HTTPException(status_code=404, detail="Settlement not found.")

    if s.status == "PAID":
        raise HTTPException(status_code=400, detail="Settlement is already marked as PAID.")

    old_status = s.status
    s.status = "PAID"

    client_ip = request.client.host if request.client else None
    desc = f"Admin {current_admin.email} marked Settlement {s.id} as PAID (Ext Ref: {payload.payment_reference}). Notes: {payload.notes or 'None'}"
    log_activity(
        db,
        admin=current_admin,
        action="RECONCILE_SETTLEMENT",
        module="SETTLEMENTS",
        record_id=str(s.id),
        description=desc,
        changes={
            "old_status": old_status,
            "new_status": "PAID",
            "payment_reference": payload.payment_reference,
            "notes": payload.notes,
        },
        ip_address=client_ip,
    )
    db.commit()

    return {"message": "Settlement reconciled successfully.", "status": "PAID", "payment_reference": payload.payment_reference}


# ---------------------------------------------------------------------------
# Mandi Prices
# ---------------------------------------------------------------------------

@router.get("/mandi/prices")
async def get_admin_mandi_prices(
    district: Optional[str] = None,
    crop: Optional[str] = None,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
):
    """
    Retrieve mandi prices with transparent data source indicator ('live' vs 'mock').
    """
    import main

    district_filter = None
    if district and district.strip() and district.lower() not in ("all", "all karnataka", "karnataka"):
        district_filter = district.strip()

    data_gov_key = main.os.environ.get("DATA_GOV_API_KEY")
    live_records = None
    source = "mock"

    if data_gov_key:
        live_records = await main._fetch_live_rates(data_gov_key, district_filter)
        if live_records:
            source = "live"

    records = []
    if live_records:
        records = live_records
    else:
        # Fallback to mock data
        if district_filter:
            records = main._mock_rates_for(district_filter)
        else:
            for dist in main._MANDI_RATE_DISTRICTS:
                records.extend(main._mock_rates_for(dist))

    # Apply crop filter if specified
    if crop and crop.strip() and crop.lower() != "all":
        c_clean = crop.strip().lower()
        records = [r for r in records if c_clean in r.get("crop", "").lower()]

    return {
        "source": source,
        "is_live_data": source == "live",
        "district": district_filter or "All Karnataka",
        "count": len(records),
        "available_districts": main._MANDI_RATE_DISTRICTS,
        "prices": records,
    }


# ---------------------------------------------------------------------------
# Reports & Analytics (with real CSV Streaming Export)
# ---------------------------------------------------------------------------

@router.get("/reports/summary")
def get_reports_summary(
    category: str = Query(..., pattern="^(farmers|riders|requests|trips|pools|settlements)$"),
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Get aggregated report metrics based on real database data.
    """
    date_filter = []
    if start_date:
        try:
            sd = datetime.fromisoformat(start_date)
            date_filter.append(models.User.created_at >= sd)
        except ValueError:
            pass
    if end_date:
        try:
            ed = datetime.fromisoformat(end_date)
            date_filter.append(models.User.created_at <= ed)
        except ValueError:
            pass

    if category == "farmers":
        farmers = db.query(models.User).filter(models.User.role == "FARMER", *date_filter).all()
        return {
            "category": "farmers",
            "total_records": len(farmers),
            "data": [
                {
                    "name": f.full_name,
                    "email": f.email,
                    "phone": f.phone_number or f.phone,
                    "district": f.district or "Karnataka",
                    "status": "ACTIVE" if getattr(f, "is_active", True) else "SUSPENDED",
                    "registered_on": f.created_at.strftime("%Y-%m-%d %H:%M") if f.created_at else "-",
                }
                for f in farmers
            ],
        }

    elif category == "riders":
        riders = db.query(models.User).filter(models.User.role == "RIDER", *date_filter).all()
        return {
            "category": "riders",
            "total_records": len(riders),
            "data": [
                {
                    "name": r.full_name,
                    "phone": r.phone_number or r.phone,
                    "vehicle": f"{r.vehicle_type or 'Vehicle'} ({r.vehicle_number or 'N/A'})",
                    "capacity_kg": r.payload_capacity_kg or 0,
                    "duty_status": "ON DUTY" if r.is_on_duty else "OFF DUTY",
                    "status": "ACTIVE" if getattr(r, "is_active", True) else "SUSPENDED",
                    "registered_on": r.created_at.strftime("%Y-%m-%d %H:%M") if r.created_at else "-",
                }
                for r in riders
            ],
        }

    elif category == "requests":
        reqs = db.query(models.ProduceRequest).options(joinedload(models.ProduceRequest.farmer)).all()
        return {
            "category": "requests",
            "total_records": len(reqs),
            "data": [
                {
                    "id": str(r.id)[:8],
                    "farmer": r.farmer.full_name if r.farmer else "Unknown",
                    "crop": r.crop_type,
                    "weight_kg": float(r.weight_kg or 0),
                    "district": r.dropoff_district or "-",
                    "status": r.status,
                    "date": r.created_at.strftime("%Y-%m-%d") if r.created_at else "-",
                }
                for r in reqs
            ],
        }

    elif category == "trips":
        trips = (
            db.query(models.Trip)
            .options(
                joinedload(models.Trip.rider),
                joinedload(models.Trip.produce_request),
            )
            .all()
        )
        return {
            "category": "trips",
            "total_records": len(trips),
            "data": [
                {
                    "id": str(t.id)[:8],
                    "rider": t.rider.full_name if t.rider else "Unassigned",
                    "crop": t.produce_request.crop_type if t.produce_request else "-",
                    "status": t.status,
                    "pickup": t.pickup_address or "Origin",
                    "date": t.created_at.strftime("%Y-%m-%d") if t.created_at else "-",
                }
                for t in trips
            ],
        }

    elif category == "pools":
        from pools.models import Pool, PoolMember
        pools = db.query(Pool).all()
        return {
            "category": "pools",
            "total_records": len(pools),
            "data": [
                {
                    "id": str(p.id)[:8],
                    "crop": p.crop_type,
                    "current_qty": p.current_qty,
                    "max_qty": p.max_qty,
                    "district": p.dropoff_district or "-",
                    "status": p.status,
                    "created_at": p.created_at.strftime("%Y-%m-%d") if p.created_at else "-",
                }
                for p in pools
            ],
        }

    elif category == "settlements":
        settlements = db.query(models.Settlement).all()
        return {
            "category": "settlements",
            "total_records": len(settlements),
            "data": [
                {
                    "id": str(s.id)[:8],
                    "crop": s.crop_name or "Produce",
                    "gross_amount": s.gross_amount or 0.0,
                    "platform_fee": s.platform_fee or 0.0,
                    "net_payout": s.net_payout or s.total_payout,
                    "status": s.status,
                    "created_at": s.created_at.strftime("%Y-%m-%d") if s.created_at else "-",
                }
                for s in settlements
            ],
        }


@router.get("/reports/export")
def export_report_csv(
    category: str = Query(..., pattern="^(farmers|riders|requests|trips|pools|settlements)$"),
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Stream real database records as a downloadable CSV spreadsheet.
    """
    output = io.StringIO()
    writer = csv.writer(output)

    if category == "farmers":
        writer.writerow(["Farmer Name", "Email", "Phone", "District", "Farm Size (Acres)", "Primary Crops", "Status", "Registration Date"])
        farmers = db.query(models.User).filter(models.User.role == "FARMER").order_by(models.User.created_at.desc()).all()
        for f in farmers:
            writer.writerow([
                f.full_name,
                f.email,
                f.phone_number or f.phone or "-",
                f.district or "Karnataka",
                f.farm_size_acres or "-",
                f.primary_crops or "-",
                "ACTIVE" if getattr(f, "is_active", True) else "SUSPENDED",
                f.created_at.strftime("%Y-%m-%d %H:%M:%S") if f.created_at else "-",
            ])

    elif category == "riders":
        writer.writerow(["Rider Name", "Email", "Phone", "Vehicle Type", "Vehicle Number", "Payload Capacity (KG)", "Operating Routes", "Duty Status", "Account Status", "Registration Date"])
        riders = db.query(models.User).filter(models.User.role == "RIDER").order_by(models.User.created_at.desc()).all()
        for r in riders:
            writer.writerow([
                r.full_name,
                r.email,
                r.phone_number or r.phone or "-",
                r.vehicle_type or "-",
                r.vehicle_number or "-",
                r.payload_capacity_kg or "-",
                r.operating_routes or "-",
                "ON DUTY" if r.is_on_duty else "OFF DUTY",
                "ACTIVE" if getattr(r, "is_active", True) else "SUSPENDED",
                r.created_at.strftime("%Y-%m-%d %H:%M:%S") if r.created_at else "-",
            ])

    elif category == "requests":
        writer.writerow(["Request ID", "Farmer Name", "Crop", "Weight (KG)", "Pickup Address", "Dropoff Mandi", "District", "Status", "Created At"])
        reqs = db.query(models.ProduceRequest).options(joinedload(models.ProduceRequest.farmer)).order_by(models.ProduceRequest.created_at.desc()).all()
        for r in reqs:
            writer.writerow([
                str(r.id),
                r.farmer.full_name if r.farmer else "Unknown",
                r.crop_type,
                r.weight_kg or 0,
                r.pickup_address or "Farm Gate",
                r.dropoff_mandi_name or r.dropoff_location or "-",
                r.dropoff_district or "-",
                r.status,
                r.created_at.strftime("%Y-%m-%d %H:%M:%S") if r.created_at else "-",
            ])

    elif category == "trips":
        writer.writerow(["Trip ID", "Rider Name", "Farmer Name", "Crop", "Pickup Location", "Destination", "Status", "Created At", "Completed At"])
        trips = (
            db.query(models.Trip)
            .options(
                joinedload(models.Trip.rider),
                joinedload(models.Trip.produce_request).joinedload(models.ProduceRequest.farmer),
            )
            .order_by(models.Trip.created_at.desc())
            .all()
        )
        for t in trips:
            pr = t.produce_request
            farmer = pr.farmer if pr else None
            writer.writerow([
                str(t.id),
                t.rider.full_name if t.rider else "Unassigned",
                farmer.full_name if farmer else "Unknown",
                pr.crop_type if pr else "-",
                t.pickup_address or "-",
                pr.dropoff_mandi_name if pr else "-",
                t.status,
                t.created_at.strftime("%Y-%m-%d %H:%M:%S") if t.created_at else "-",
                t.completed_at.strftime("%Y-%m-%d %H:%M:%S") if t.completed_at else "-",
            ])

    elif category == "pools":
        from pools.models import Pool, PoolMember
        writer.writerow(["Pool ID", "Creator ID", "Crop", "Current QTY (KG)", "Min QTY", "Max QTY", "District", "Mandi", "Status", "Created At"])
        pools = db.query(Pool).order_by(Pool.created_at.desc()).all()
        for p in pools:
            writer.writerow([
                str(p.id),
                str(p.creator_id),
                p.crop_type,
                p.current_qty,
                p.min_qty,
                p.max_qty,
                p.dropoff_district or "-",
                p.dropoff_mandi_name or "-",
                p.status,
                p.created_at.strftime("%Y-%m-%d %H:%M:%S") if p.created_at else "-",
            ])

    elif category == "settlements":
        writer.writerow(["Settlement ID", "Trip ID", "Crop", "Quantity (KG)", "Gross Amount (INR)", "Platform Fee (INR)", "Rider Fare (INR)", "Net Payout (INR)", "Status", "Date"])
        settlements = db.query(models.Settlement).order_by(models.Settlement.created_at.desc()).all()
        for s in settlements:
            writer.writerow([
                str(s.id),
                str(s.trip_id),
                s.crop_name or "-",
                s.quantity_kg or 0,
                s.gross_amount or 0.0,
                s.platform_fee or 0.0,
                s.rider_fare or 0.0,
                s.net_payout or s.total_payout,
                s.status,
                s.created_at.strftime("%Y-%m-%d %H:%M:%S") if s.created_at else "-",
            ])

    output.seek(0)
    filename = f"kisanrider_{category}_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    return StreamingResponse(
        iter([output.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )


# ---------------------------------------------------------------------------
# Admin Management & Invitation Workflow
# ---------------------------------------------------------------------------

@router.get("/admins")
def list_admins(
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    List all active admins and pending unexpired invitations.
    """
    admins = (
        db.query(models.User)
        .filter(models.User.role == "ADMIN")
        .order_by(models.User.created_at.desc())
        .all()
    )

    now = datetime.now(timezone.utc)
    invitations = (
        db.query(models.AdminInvitation)
        .filter(
            models.AdminInvitation.accepted_at == None,
            models.AdminInvitation.expires_at > now,
        )
        .order_by(models.AdminInvitation.created_at.desc())
        .all()
    )

    return {
        "admins": [
            {
                "id": str(a.id),
                "full_name": a.full_name,
                "email": a.email,
                "is_active": getattr(a, "is_active", True),
                "created_at": a.created_at.isoformat() if a.created_at else None,
            }
            for a in admins
        ],
        "pending_invitations": [
            {
                "id": str(inv.id),
                "full_name": inv.full_name,
                "email": inv.email,
                "created_at": inv.created_at.isoformat() if inv.created_at else None,
                "expires_at": inv.expires_at.isoformat() if inv.expires_at else None,
            }
            for inv in invitations
        ],
    }


@router.post("/admins/invite")
def invite_admin(
    payload: AdminInviteRequest,
    request: Request,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Create a secure invitation for an additional Admin.
    Generates cryptographically random token, stores SHA-256 hash.
    Sets 24 hour expiry. Dispatches invitation email or logs accurately.
    """
    email_clean = payload.email.strip().lower()

    # 1. Check if user already exists
    existing = crud.get_user_by_email(db, email_clean)
    if existing:
        raise HTTPException(
            status_code=400,
            detail=f"An account with email {email_clean} already exists ({existing.role}).",
        )

    # 2. Revoke any prior unaccepted invitations for this email
    db.query(models.AdminInvitation).filter(
        models.AdminInvitation.email == email_clean,
        models.AdminInvitation.accepted_at == None,
    ).delete(synchronize_session=False)

    # 3. Generate raw token and hash
    raw_token = secrets.token_urlsafe(32)
    token_hash = hashlib.sha256(raw_token.encode("utf-8")).hexdigest()

    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(hours=24)

    invitation = models.AdminInvitation(
        id=uuid4(),
        email=email_clean,
        full_name=payload.full_name.strip(),
        token_hash=token_hash,
        invited_by_id=current_admin.id,
        created_at=now,
        expires_at=expires_at,
    )
    db.add(invitation)

    # 4. Attempt email dispatch using configured SMTP
    email_sent = False
    if config.SMTP_EMAIL and config.SMTP_PASSWORD:
        try:
            import smtplib
            from email.mime.multipart import MIMEMultipart
            from email.mime.text import MIMEText

            msg = MIMEMultipart()
            msg["From"] = config.SMTP_EMAIL
            msg["To"] = email_clean
            msg["Subject"] = "Invitation to Join KisanRider Admin Team"

            invite_link = f"http://localhost:5173/accept-invitation?token={raw_token}"
            body_text = (
                f"Hello {payload.full_name},\n\n"
                f"You have been invited by {current_admin.full_name} ({current_admin.email}) "
                f"to join the KisanRider platform as an Administrator.\n\n"
                f"Please open the following link to set your password and activate your account:\n"
                f"{invite_link}\n\n"
                f"This single-use invitation expires in 24 hours.\n\n"
                f"Regards,\nKisanRider Team"
            )
            msg.attach(MIMEText(body_text, "plain"))

            server = smtplib.SMTP_SSL(config.SMTP_SERVER, config.SMTP_PORT, timeout=15)
            server.login(config.SMTP_EMAIL, config.SMTP_PASSWORD)
            server.send_message(msg)
            server.quit()
            email_sent = True
        except Exception as e:
            print(f"[Admin Invite] Email dispatch warning: {e}")
            email_sent = False

    # 5. Log in audit log
    client_ip = request.client.host if request.client else None
    desc = f"Admin {current_admin.email} invited {email_clean} as Administrator (Email sent: {email_sent})."
    log_activity(
        db,
        admin=current_admin,
        action="INVITE_ADMIN",
        module="ADMIN_MANAGEMENT",
        record_id=str(invitation.id),
        description=desc,
        changes={"email": email_clean, "full_name": payload.full_name, "email_sent": email_sent},
        ip_address=client_ip,
    )
    db.commit()

    return {
        "success": True,
        "message": "Admin invitation created successfully.",
        "invitation_id": str(invitation.id),
        "email_sent": email_sent,
        # For development / verification without external SMTP:
        "invite_token": raw_token,
    }


@router.post("/admins/resend-invite")
def resend_admin_invite(
    payload: AdminResendInviteRequest,
    request: Request,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Resend an unaccepted admin invitation with a fresh token and renewed 24-hour expiry.
    """
    inv = db.query(models.AdminInvitation).filter(models.AdminInvitation.id == payload.invitation_id).first()
    if not inv or inv.accepted_at is not None:
        raise HTTPException(status_code=404, detail="Active invitation not found.")

    raw_token = secrets.token_urlsafe(32)
    inv.token_hash = hashlib.sha256(raw_token.encode("utf-8")).hexdigest()
    inv.created_at = datetime.now(timezone.utc)
    inv.expires_at = datetime.now(timezone.utc) + timedelta(hours=24)

    client_ip = request.client.host if request.client else None
    desc = f"Admin {current_admin.email} renewed invitation token for {inv.email}."
    log_activity(
        db,
        admin=current_admin,
        action="RESEND_ADMIN_INVITE",
        module="ADMIN_MANAGEMENT",
        record_id=str(inv.id),
        description=desc,
        changes={"email": inv.email},
        ip_address=client_ip,
    )
    db.commit()

    return {
        "success": True,
        "message": "Invitation renewed successfully.",
        "invitation_id": str(inv.id),
        "invite_token": raw_token,
    }


@router.post("/admins/accept-invite")
def accept_admin_invite(
    payload: AdminAcceptInviteRequest,
    request: Request,
    db: Session = Depends(get_db),
):
    """
    Accept single-use invitation token, set password, and activate Admin account.
    Validates token hash, prevents expired token use, prevents duplicate emails.
    """
    token_hash = hashlib.sha256(payload.token.strip().encode("utf-8")).hexdigest()
    now = datetime.now(timezone.utc)

    inv = (
        db.query(models.AdminInvitation)
        .filter(
            models.AdminInvitation.token_hash == token_hash,
            models.AdminInvitation.accepted_at == None,
        )
        .first()
    )

    if not inv:
        raise HTTPException(status_code=400, detail="Invalid or already used invitation token.")

    # Check expiration
    if inv.expires_at < now:
        raise HTTPException(status_code=400, detail="This invitation link has expired. Request a new invite.")

    # Check if user email was already registered in the meantime
    if crud.get_user_by_email(db, inv.email):
        raise HTTPException(status_code=400, detail=f"User with email {inv.email} is already registered.")

    # Create new Admin user
    password_hash = auth.hash_password(payload.password)
    new_admin = models.User(
        id=uuid4(),
        email=inv.email,
        full_name=inv.full_name,
        role="ADMIN",
        password_hash=password_hash,
        is_verified=True,
        is_active=True,
        state="Karnataka",
    )
    db.add(new_admin)

    # Mark invitation accepted
    inv.accepted_at = now

    # Log in audit log
    client_ip = request.client.host if request.client else None
    desc = f"New Admin {new_admin.full_name} ({new_admin.email}) accepted invitation and activated account."
    log_activity(
        db,
        admin=new_admin,
        action="ACCEPT_ADMIN_INVITE",
        module="ADMIN_MANAGEMENT",
        record_id=str(new_admin.id),
        description=desc,
        changes={"email": new_admin.email, "full_name": new_admin.full_name},
        ip_address=client_ip,
    )
    db.commit()

    return {
        "success": True,
        "message": "Admin account activated successfully. You can now log in.",
    }


# ---------------------------------------------------------------------------
# Admin Activity Logs (Read-only Audit Log)
# ---------------------------------------------------------------------------

@router.get("/activity-logs")
def list_activity_logs(
    admin_id: Optional[UUID] = None,
    module: Optional[str] = None,
    action: Optional[str] = None,
    search: Optional[str] = None,
    page: int = Query(1, ge=1),
    limit: int = Query(15, ge=1, le=100),
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Read-only audit log inspection with filtering and search.
    No edit or delete endpoints exist for audit logs.
    """
    query = db.query(models.AdminActivityLog)

    if admin_id:
        query = query.filter(models.AdminActivityLog.admin_id == admin_id)

    if module and module.strip() and module.lower() != "all":
        query = query.filter(models.AdminActivityLog.module == module.strip().upper())

    if action and action.strip() and action.lower() != "all":
        query = query.filter(models.AdminActivityLog.action == action.strip().upper())

    if search and search.strip():
        term = f"%{search.strip().lower()}%"
        query = query.filter(
            or_(
                func.lower(models.AdminActivityLog.description).like(term),
                func.lower(models.AdminActivityLog.admin_email).like(term),
                func.lower(models.AdminActivityLog.admin_name).like(term),
                models.AdminActivityLog.record_id.like(term),
            )
        )

    total_count = query.count()
    offset = (page - 1) * limit
    logs_rows = (
        query.order_by(models.AdminActivityLog.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )

    items = [
        {
            "id": str(l.id),
            "admin_id": str(l.admin_id) if l.admin_id else None,
            "admin_email": l.admin_email,
            "admin_name": l.admin_name,
            "action": l.action,
            "module": l.module,
            "record_id": l.record_id,
            "description": l.description,
            "changes": json.loads(l.changes) if l.changes else None,
            "ip_address": l.ip_address,
            "created_at": l.created_at.isoformat() if l.created_at else None,
        }
        for l in logs_rows
    ]

    return {
        "items": items,
        "total": total_count,
        "page": page,
        "limit": limit,
        "total_pages": (total_count + limit - 1) // limit if total_count > 0 else 1,
    }


@router.get("/activity-logs/{log_id}")
def get_activity_log_detail(
    log_id: UUID,
    current_admin: models.User = Depends(auth.require_role("ADMIN")),
    db: Session = Depends(get_db),
):
    """
    Get full details of a specific audit log record.
    """
    log = db.query(models.AdminActivityLog).filter(models.AdminActivityLog.id == log_id).first()
    if not log:
        raise HTTPException(status_code=404, detail="Activity log not found.")

    return {
        "id": str(log.id),
        "admin_id": str(log.admin_id) if log.admin_id else None,
        "admin_email": log.admin_email,
        "admin_name": log.admin_name,
        "action": log.action,
        "module": log.module,
        "record_id": log.record_id,
        "description": log.description,
        "changes": json.loads(log.changes) if log.changes else None,
        "ip_address": log.ip_address,
        "created_at": log.created_at.isoformat() if log.created_at else None,
    }
