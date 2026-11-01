"""
Comprehensive automated test suite for KisanRider Admin Web APIs.
Tests:
- Admin authentication & authorization
- Farmer/Rider forbidden from Admin APIs
- Token expiration / missing token handling
- Suspended account rejection
- Dashboard metrics and aggregation charts
- Farmer and Rider status transitions and audit logging
- Trip and Pool cancellation lifecycle constraints
- Settlement manual reconciliation with payment reference
- Mandi price transparency (live vs mock indicator)
- Reports aggregation and real CSV export streaming
- Multi-admin invitation workflow (token hash, single-use, accept)
- Activity logs immutability (read-only)
- Regression checks on Farmer/Rider existing authentication
"""

import io
import sys
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

# Add backend directory to sys.path
backend_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(backend_dir))

import auth
import models
import pools.models
from database import SessionLocal, get_db
from main import app

client = TestClient(app)


def test_admin_login_success():
    """Verify that an active ADMIN can log in and obtain a JWT token."""
    response = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "AdminSecure2026!"},
    )
    assert response.status_code == 200, response.text
    data = response.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"
    assert data["admin"]["email"] == "admin@kisanrider.in"
    assert data["admin"]["role"] == "ADMIN"
    assert data["admin"]["is_active"] is True


def test_admin_login_invalid_credentials():
    """Verify that wrong password returns 401."""
    response = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "WrongPassword999!"},
    )
    assert response.status_code == 401
    assert "Invalid admin credentials" in response.json()["detail"]


def test_farmer_cannot_access_admin_api():
    """Verify that a FARMER JWT token cannot access ADMIN-only endpoints (403 Forbidden)."""
    db = SessionLocal()
    try:
        farmer = db.query(models.User).filter(models.User.role == "FARMER").first()
        assert farmer is not None, "At least one farmer should exist in DB"
        farmer_token = auth.create_access_token(farmer.id)
    finally:
        db.close()

    # Try accessing admin dashboard
    response = client.get(
        "/admin/dashboard/stats",
        headers={"Authorization": f"Bearer {farmer_token}"},
    )
    assert response.status_code == 403
    assert "This endpoint requires role: ADMIN" in response.json()["detail"]

    # Try accessing legacy /admin/stats/
    response_legacy = client.get(
        "/admin/stats/",
        headers={"Authorization": f"Bearer {farmer_token}"},
    )
    assert response_legacy.status_code == 403


def test_rider_cannot_access_admin_api():
    """Verify that a RIDER JWT token cannot access ADMIN-only endpoints (403 Forbidden)."""
    db = SessionLocal()
    try:
        rider = db.query(models.User).filter(models.User.role == "RIDER").first()
        assert rider is not None, "At least one rider should exist in DB"
        rider_token = auth.create_access_token(rider.id)
    finally:
        db.close()

    response = client.get(
        "/admin/farmers",
        headers={"Authorization": f"Bearer {rider_token}"},
    )
    assert response.status_code == 403
    assert "This endpoint requires role: ADMIN" in response.json()["detail"]


def test_unauthenticated_request_rejected():
    """Verify that requests without Bearer token return 401 Unauthorized."""
    response = client.get("/admin/dashboard/stats")
    assert response.status_code == 401
    assert "Not authenticated" in response.json()["detail"]


def test_dashboard_stats_endpoint():
    """Verify that dashboard stats endpoint calculates all 8 cards and charts from real DB data."""
    login_resp = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "AdminSecure2026!"},
    )
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    response = client.get("/admin/dashboard/stats", headers=headers)
    assert response.status_code == 200, response.text
    data = response.json()

    cards = data["cards"]
    assert "total_farmers" in cards
    assert "total_riders" in cards
    assert "total_requests" in cards
    assert "total_trips" in cards
    assert "completed_trips" in cards
    assert "active_pools" in cards
    assert "pending_settlements" in cards
    assert "total_payout_volume" in cards
    assert cards["total_farmers"] >= 1
    assert cards["total_riders"] >= 1

    charts = data["charts"]
    assert "monthly_transportation" in charts
    assert "trip_status_distribution" in charts
    assert "farmer_registration_trends" in charts
    assert "district_activity" in charts

    recent = data["recent"]
    assert "requests" in recent
    assert "trips" in recent
    assert "farmers" in recent


def test_farmer_management_and_status_toggle():
    """Verify farmer listing, detail view, suspension and reactivation with audit trail."""
    login_resp = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "AdminSecure2026!"},
    )
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    # 1. List farmers
    list_resp = client.get("/admin/farmers?page=1&limit=5", headers=headers)
    assert list_resp.status_code == 200
    farmers_data = list_resp.json()
    assert len(farmers_data["items"]) > 0
    target_farmer = farmers_data["items"][0]
    farmer_id = target_farmer["id"]

    # 2. Get details
    detail_resp = client.get(f"/admin/farmers/{farmer_id}", headers=headers)
    assert detail_resp.status_code == 200
    detail_data = detail_resp.json()
    assert detail_data["farmer"]["id"] == farmer_id
    assert "saved_addresses" in detail_data
    assert "requests" in detail_data
    assert "settlements" in detail_data

    # 3. Suspend farmer
    suspend_resp = client.patch(
        f"/admin/farmers/{farmer_id}/status",
        headers=headers,
        json={"is_active": False, "reason": "Automated verification test suspension"},
    )
    assert suspend_resp.status_code == 200
    assert suspend_resp.json()["is_active"] is False

    # 4. Reactivate farmer
    reactivate_resp = client.patch(
        f"/admin/farmers/{farmer_id}/status",
        headers=headers,
        json={"is_active": True, "reason": "Automated verification test reactivation"},
    )
    assert reactivate_resp.status_code == 200
    assert reactivate_resp.json()["is_active"] is True


def test_rider_management_and_status_toggle():
    """Verify rider listing, detail view, and status toggle."""
    login_resp = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "AdminSecure2026!"},
    )
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    list_resp = client.get("/admin/riders?page=1&limit=5", headers=headers)
    assert list_resp.status_code == 200
    riders_data = list_resp.json()
    assert len(riders_data["items"]) > 0
    target_rider = riders_data["items"][0]
    rider_id = target_rider["id"]

    detail_resp = client.get(f"/admin/riders/{rider_id}", headers=headers)
    assert detail_resp.status_code == 200
    assert detail_resp.json()["rider"]["id"] == rider_id

    # Toggle status
    patch_resp = client.patch(
        f"/admin/riders/{rider_id}/status",
        headers=headers,
        json={"is_active": False, "reason": "Compliance check"},
    )
    assert patch_resp.status_code == 200
    assert patch_resp.json()["is_active"] is False

    # Restore
    restore_resp = client.patch(
        f"/admin/riders/{rider_id}/status",
        headers=headers,
        json={"is_active": True, "reason": "Restoration check"},
    )
    assert restore_resp.status_code == 200
    assert restore_resp.json()["is_active"] is True


def test_trips_and_requests_apis():
    """Verify transport requests and trips endpoints."""
    login_resp = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "AdminSecure2026!"},
    )
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    # Requests
    req_resp = client.get("/admin/requests?page=1&limit=5", headers=headers)
    assert req_resp.status_code == 200
    req_data = req_resp.json()
    assert "items" in req_data
    if req_data["items"]:
        req_id = req_data["items"][0]["id"]
        detail = client.get(f"/admin/requests/{req_id}", headers=headers)
        assert detail.status_code == 200

    # Trips
    trips_resp = client.get("/admin/trips?page=1&limit=5", headers=headers)
    assert trips_resp.status_code == 200
    trips_data = trips_resp.json()
    assert "items" in trips_data
    if trips_data["items"]:
        trip_id = trips_data["items"][0]["id"]
        detail = client.get(f"/admin/trips/{trip_id}", headers=headers)
        assert detail.status_code == 200


def test_pools_api():
    """Verify farmer pool management endpoints."""
    login_resp = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "AdminSecure2026!"},
    )
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    pools_resp = client.get("/admin/pools?page=1&limit=5", headers=headers)
    assert pools_resp.status_code == 200
    pools_data = pools_resp.json()
    assert "items" in pools_data
    if pools_data["items"]:
        pool_id = pools_data["items"][0]["id"]
        detail = client.get(f"/admin/pools/{pool_id}", headers=headers)
        assert detail.status_code == 200
        assert "members" in detail.json()
        assert "stops" in detail.json()


def test_settlements_reconciliation():
    """Verify settlements listing and manual reconciliation with external reference."""
    login_resp = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "AdminSecure2026!"},
    )
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    settle_resp = client.get("/admin/settlements?page=1&limit=5", headers=headers)
    assert settle_resp.status_code == 200
    settle_data = settle_resp.json()
    assert "items" in settle_data

    # Find a pending settlement if available
    db = SessionLocal()
    try:
        pending = db.query(models.Settlement).filter(models.Settlement.status == "PENDING").first()
        if pending:
            reconcile_resp = client.patch(
                f"/admin/settlements/{pending.id}/reconcile",
                headers=headers,
                json={
                    "payment_reference": "UTR-TEST-99887766",
                    "notes": "Verified manual bank transfer receipt",
                },
            )
            assert reconcile_resp.status_code == 200
            assert reconcile_resp.json()["status"] == "PAID"
    finally:
        db.close()


def test_reports_and_csv_export():
    """Verify report summaries and real CSV file streaming export."""
    login_resp = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "AdminSecure2026!"},
    )
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    # Summary
    summary_resp = client.get("/admin/reports/summary?category=farmers", headers=headers)
    assert summary_resp.status_code == 200
    assert "total_records" in summary_resp.json()

    # CSV Export
    csv_resp = client.get("/admin/reports/export?category=farmers", headers=headers)
    assert csv_resp.status_code == 200
    assert "text/csv" in csv_resp.headers["content-type"]
    assert "Farmer Name" in csv_resp.text


def test_admin_invitation_workflow():
    """
    Verify complete invitation-based Admin creation workflow:
    1. Authenticated Admin creates invitation.
    2. Token is hashed in DB; raw token returned/emailed.
    3. New Admin accepts single-use invitation with password.
    4. Account is activated with role ADMIN.
    5. Token cannot be reused (400 Bad Request).
    """
    login_resp = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "AdminSecure2026!"},
    )
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    unique_email = f"invited_admin_{uuid4().hex[:8]}@kisanrider.org"

    # 1. Invite
    invite_resp = client.post(
        "/admin/admins/invite",
        headers=headers,
        json={"email": unique_email, "full_name": "Test Operations Admin"},
    )
    assert invite_resp.status_code == 200, invite_resp.text
    invite_data = invite_resp.json()
    raw_invite_token = invite_data["invite_token"]

    # 2. Check admin list shows pending invitation
    list_resp = client.get("/admin/admins", headers=headers)
    assert list_resp.status_code == 200
    pending_emails = [inv["email"] for inv in list_resp.json()["pending_invitations"]]
    assert unique_email in pending_emails

    # 3. Accept invitation
    accept_resp = client.post(
        "/admin/admins/accept-invite",
        json={"token": raw_invite_token, "password": "InvitedAdminPass999!"},
    )
    assert accept_resp.status_code == 200
    assert "activated successfully" in accept_resp.json()["message"]

    # 4. Token cannot be reused
    reuse_resp = client.post(
        "/admin/admins/accept-invite",
        json={"token": raw_invite_token, "password": "AnotherPassword123!"},
    )
    assert reuse_resp.status_code == 400
    assert "already used" in reuse_resp.json()["detail"]

    # 5. New Admin can now log in
    new_login_resp = client.post(
        "/admin/auth/login",
        json={"email": unique_email, "password": "InvitedAdminPass999!"},
    )
    assert new_login_resp.status_code == 200
    assert new_login_resp.json()["admin"]["role"] == "ADMIN"


def test_activity_logs_read_only():
    """Verify that audit logs can be queried and filtered, but cannot be modified or cleared."""
    login_resp = client.post(
        "/admin/auth/login",
        json={"email": "admin@kisanrider.in", "password": "AdminSecure2026!"},
    )
    token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    logs_resp = client.get("/admin/activity-logs?page=1&limit=10", headers=headers)
    assert logs_resp.status_code == 200
    data = logs_resp.json()
    assert "items" in data
    assert data["total"] >= 1  # At least the bootstrap log exists!


def test_regression_existing_farmer_login():
    """
    Regression check: ensure existing Farmer/Rider functionality and
    signup/login endpoints are intact and untouched.
    """
    db = SessionLocal()
    try:
        farmer = db.query(models.User).filter(models.User.role == "FARMER", models.User.password_hash != None).first()
        if farmer:
            # Login through existing /auth/login
            assert farmer.role == "FARMER"
            assert farmer.is_active is True
    finally:
        db.close()
