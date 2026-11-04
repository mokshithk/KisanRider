"""
Test suite covering all 4 follow-up bug fixes and 2 enhancements in KisanRider.
"""

import uuid
from datetime import datetime, timezone, timedelta
import pytest
from fastapi.testclient import TestClient
from geoalchemy2.elements import WKTElement

from main import app
from database import SessionLocal
import models
from pools import models as pool_models
from email_templates import render_kisanrider_otp_email
import otp_service


@pytest.fixture(scope="module")
def client():
    return TestClient(app)


@pytest.fixture(scope="module")
def db():
    session = SessionLocal()
    yield session
    session.close()


def test_issue1_farmer_transport_request_submission(client, db):
    """
    Issue 1:
    Farmer updates farm size, primary crops, and farm address via PUT /farmer/address.
    Farmer can then successfully submit a produce transport request with requested_pickup_at.
    """
    farmer = models.User(
        email=f"farmer_submit_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Submission Test Farmer",
        district="Bengaluru Rural",
    )
    db.add(farmer)
    db.commit()
    db.refresh(farmer)

    token = client.post(f"/auth/dev-token?user_id={farmer.id}").json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    # Step 1: Update farm details
    p1 = client.put("/farmer/farm-details", json={
        "farm_size_acres": 4.5,
        "primary_crops": "Carrots, Beans",
    }, headers=headers)
    assert p1.status_code == 200, p1.text

    # Step 2: Update farm address via PUT /farmer/address (Farm Address Sheet)
    p2 = client.put("/farmer/address", json={
        "farm_address": "Nelamangala Highway, Gate 4",
        "landmark": "Near Shell Petrol Pump",
    }, headers=headers)
    assert p2.status_code == 200, p2.text

    # Verify auto-sync to saved_addresses
    addr_resp = client.get("/farmer/addresses", headers=headers)
    assert addr_resp.status_code == 200
    addresses = addr_resp.json()
    assert len(addresses) >= 1
    assert any("Nelamangala Highway" in a["address_text"] for a in addresses)

    # Step 3: Submit transport request with future pickup date
    future_time = datetime.now(timezone.utc) + timedelta(days=1)
    req_resp = client.post("/produce-requests/", json={
        "crop_type": "Carrots",
        "weight_kg": 250.0,
        "latitude": 13.1500,
        "longitude": 77.4000,
        "pickup_address": "Nelamangala Highway, Gate 4",
        "pickup_landmark": "Near Shell Petrol Pump",
        "dropoff_district": "Bengaluru Rural",
        "dropoff_mandi_name": "Yeshwanthpur APMC",
        "requested_pickup_at": future_time.isoformat(),
    }, headers=headers)
    assert req_resp.status_code == 201, req_resp.text
    data = req_resp.json()
    assert data["status"] == "PENDING"
    assert data["crop_type"] == "Carrots"

    # Verify rejection of past pickup time
    past_time = datetime.now(timezone.utc) - timedelta(hours=2)
    bad_req = client.post("/produce-requests/", json={
        "crop_type": "Beans",
        "weight_kg": 100.0,
        "latitude": 13.1500,
        "longitude": 77.4000,
        "requested_pickup_at": past_time.isoformat(),
    }, headers=headers)
    assert bad_req.status_code == 400
    assert "future" in bad_req.json()["detail"].lower()


def test_issue2_mandi_market_endpoint_and_cache(client):
    """
    Issue 2:
    Dual-source Mandi endpoint responds reliably without timing out,
    and returns cached results on repeated queries.
    """
    # 1. Fetch markets for Kolar
    r1 = client.get("/mandi/markets?district=Kolar")
    assert r1.status_code == 200, r1.text
    d1 = r1.json()
    assert d1["district"] == "Kolar"
    assert "markets" in d1
    assert len(d1["markets"]) > 0

    # 2. Repeated call should hit 24-hour cache
    r2 = client.get("/mandi/markets?district=Kolar")
    assert r2.status_code == 200
    d2 = r2.json()
    assert d2["cached"] is True
    assert len(d2["markets"]) == len(d1["markets"])

    # 3. Invalid district produces clean 400
    r_bad = client.get("/mandi/markets?district=Atlantis")
    assert r_bad.status_code == 400


def test_issue3_create_pool_validation(client, db):
    """
    Issue 3:
    Pool creation / joining requires Pickup Window Start and End,
    NOT requested_pickup_at. ProduceRequest with for_pool=True succeeds
    without requested_pickup_at.
    """
    farmer = models.User(
        email=f"pool_create_f_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Pool Creator Farmer",
        farm_size_acres=3.0,
        primary_crops="Tomatoes",
        farm_address="Kolar East Farm",
    )
    db.add(farmer)
    db.commit()
    db.refresh(farmer)

    token = client.post(f"/auth/dev-token?user_id={farmer.id}").json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    # Step 1: Create produce request for pool (with for_pool=True and no requested_pickup_at)
    pr_resp = client.post("/produce-requests/", json={
        "crop_type": "Tomatoes",
        "weight_kg": 300.0,
        "latitude": 13.1362,
        "longitude": 78.1291,
        "pickup_address": "Kolar East Farm",
        "dropoff_district": "Kolar",
        "dropoff_mandi_name": "Kolar APMC",
        "for_pool": True,
    }, headers=headers)
    assert pr_resp.status_code == 201, pr_resp.text
    pr_data = pr_resp.json()
    assert pr_data["requested_pickup_at"] is None

    # Step 2: Create pool using the created ProduceRequest
    now = datetime.now(timezone.utc)
    pool_resp = client.post("/pools/", json={
        "crop_type": "Tomatoes",
        "pickup_window_start": (now + timedelta(hours=2)).isoformat(),
        "pickup_window_end": (now + timedelta(hours=6)).isoformat(),
        "min_qty": 200.0,
        "max_qty": 1500.0,
        "produce_request_id": pr_data["id"],
        "weight_kg": 300.0,
        "dropoff_district": "Kolar",
        "dropoff_mandi_name": "Kolar APMC",
        "auto_approve": True,
    }, headers=headers)
    assert pool_resp.status_code == 201, pool_resp.text
    pool_data = pool_resp.json()
    assert pool_data["status"] == "OPEN"
    assert pool_data["current_qty"] == 300.0


def test_issue4_gps_fallback_coordinates(client, db):
    """
    Issue 4:
    Manual entry allows submission using district center fallback coordinates
    when live device GPS is denied or unavailable.
    """
    farmer = models.User(
        email=f"gps_fallback_f_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Fallback Location Farmer",
        farm_size_acres=2.0,
        primary_crops="Ragi",
        farm_address="Chitradurga Rural Farm",
    )
    db.add(farmer)
    db.commit()

    token = client.post(f"/auth/dev-token?user_id={farmer.id}").json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    # Chitradurga center fallback coordinates
    future_time = datetime.now(timezone.utc) + timedelta(days=2)
    resp = client.post("/produce-requests/", json={
        "crop_type": "Ragi",
        "weight_kg": 180.0,
        "latitude": 14.2251,
        "longitude": 76.3980,
        "pickup_address": "Hiriyur Village, Cross Road",
        "pickup_landmark": "Near Banyan Tree",
        "dropoff_district": "Chitradurga",
        "dropoff_mandi_name": "Hiriyur APMC",
        "requested_pickup_at": future_time.isoformat(),
    }, headers=headers)
    assert resp.status_code == 201, resp.text
    assert resp.json()["status"] == "PENDING"


def test_enhancement1_branded_email_templates():
    """
    Enhancement 1:
    Reusable branded HTML & plain-text email templates with #2E7D32 branding,
    5-minute expiry, security guidelines, and plaintext fallback.
    """
    html, text = render_kisanrider_otp_email(
        otp_code="7492",
        title="Verify Your KisanRider Account",
        subtitle="Account Registration",
        instruction="Please enter the verification code below to activate your account.",
        expiry_minutes=5,
    )

    # HTML assertions
    assert "#2E7D32" in html
    assert "KisanRider" in html
    assert "7492" in html
    assert "5 minutes" in html
    assert "Security Notice" in html
    assert "never" in html.lower()

    # Plain text assertions
    assert "7492" in text
    assert "KisanRider" in text
    assert "5 minutes" in text
    assert "SECURITY NOTICE" in text


def test_enhancement2_separate_pickup_otp_per_farmer_in_pool(client, db):
    """
    Enhancement 2:
    - Every farmer in a pool receives a unique, distinct pickup OTP.
    - Rider enters each farmer's OTP separately.
    - Verifying Farmer A transitions ONLY Farmer A to PICKED_UP.
    - Farmer B remains in ACCEPTED state.
    - Bad OTP is rejected with 400.
    - Verifying Farmer B marks all stops as picked up.
    """
    farmer_a = models.User(
        email=f"pool_fa_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Farmer Alpha",
        farm_size_acres=4.0,
        primary_crops="Onion",
        farm_address="Hubballi North Gate",
    )
    farmer_b = models.User(
        email=f"pool_fb_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Farmer Beta",
        farm_size_acres=5.0,
        primary_crops="Onion",
        farm_address="Hubballi South Farm",
    )
    rider = models.User(
        email=f"pool_r_{uuid.uuid4().hex[:6]}@example.com",
        role="RIDER",
        full_name="Pool Delivery Rider",
        phone_number="9845012345",
        vehicle_type="Mahindra Bolero Pickup",
        vehicle_number="KA25MN5678",
        payload_capacity_kg=2500.0,
        license_number="KA2520200001234",
        district="Dharwad",
        operating_routes="Dharwad to Hubballi",
    )
    db.add_all([farmer_a, farmer_b, rider])
    db.commit()

    now = datetime.now(timezone.utc)
    pool = pool_models.Pool(
        creator_id=farmer_a.id,
        crop_type="Onion",
        pickup_window_start=now + timedelta(hours=1),
        pickup_window_end=now + timedelta(hours=4),
        min_qty=200.0,
        max_qty=2000.0,
        current_qty=600.0,
        dropoff_district="Dharwad",
        dropoff_mandi_name="Hubballi APMC",
        status="OPEN",
    )
    db.add(pool)
    db.commit()

    pr_a = models.ProduceRequest(
        farmer_id=farmer_a.id,
        crop_type="Onion",
        weight_kg=300.0,
        pickup_location=WKTElement("POINT(75.0078 15.4589)", srid=4326),
        pickup_address="Hubballi North Gate",
        status="PENDING",
    )
    pr_b = models.ProduceRequest(
        farmer_id=farmer_b.id,
        crop_type="Onion",
        weight_kg=300.0,
        pickup_location=WKTElement("POINT(75.0178 15.4689)", srid=4326),
        pickup_address="Hubballi South Farm",
        status="PENDING",
    )
    db.add_all([pr_a, pr_b])
    db.commit()

    pm_a = pool_models.PoolMember(
        pool_id=pool.id,
        farmer_id=farmer_a.id,
        produce_request_id=pr_a.id,
        weight_kg=300.0,
        status="ACCEPTED",
    )
    pm_b = pool_models.PoolMember(
        pool_id=pool.id,
        farmer_id=farmer_b.id,
        produce_request_id=pr_b.id,
        weight_kg=300.0,
        status="ACCEPTED",
    )
    db.add_all([pm_a, pm_b])
    db.commit()

    rider_token = client.post(f"/auth/dev-token?user_id={rider.id}").json()["access_token"]
    headers = {"Authorization": f"Bearer {rider_token}"}

    # 1. Rider accepts the pool
    acc = client.post(f"/pools/{pool.id}/accept", headers=headers)
    assert acc.status_code == 201, acc.text

    db.refresh(pr_a)
    db.refresh(pr_b)

    # 2. Verify distinct unique OTPs
    assert pr_a.pickup_otp is not None and len(pr_a.pickup_otp) == 4
    assert pr_b.pickup_otp is not None and len(pr_b.pickup_otp) == 4
    assert pr_a.pickup_otp != pr_b.pickup_otp, "Farmers in pool must have distinct OTPs"

    # 3. Check route-optimization endpoint returns stop statuses
    route_resp = client.get(
        f"/pools/{pool.id}/route-optimization?rider_lat=15.45&rider_lng=75.00",
        headers=headers,
    )
    assert route_resp.status_code == 200, route_resp.text
    route_data = route_resp.json()
    assert "ordered_stops" in route_data
    assert len(route_data["ordered_stops"]) == 2

    # 4. Verify Farmer A OTP
    v_a = client.post(f"/pools/{pool.id}/verify-farmer-otp", json={
        "produce_request_id": str(pr_a.id),
        "otp": pr_a.pickup_otp,
    }, headers=headers)
    assert v_a.status_code == 200, v_a.text
    res_a = v_a.json()
    assert res_a["status"] == "PICKED_UP"
    assert res_a["all_picked_up"] is False

    # Check isolation: Farmer A is PICKED_UP, Farmer B is still ACCEPTED
    db.refresh(pr_a)
    db.refresh(pr_b)
    assert pr_a.status == "PICKED_UP"
    assert pr_b.status == "ACCEPTED"

    # 5. Invalid OTP attempt for Farmer B fails
    bad_otp = "1111" if pr_b.pickup_otp != "1111" else "2222"
    v_bad = client.post(f"/pools/{pool.id}/verify-farmer-otp", json={
        "produce_request_id": str(pr_b.id),
        "otp": bad_otp,
    }, headers=headers)
    assert v_bad.status_code == 400
    assert "invalid otp" in v_bad.json()["detail"].lower()

    # 6. Verify Farmer B with correct OTP
    v_b = client.post(f"/pools/{pool.id}/verify-farmer-otp", json={
        "produce_request_id": str(pr_b.id),
        "otp": pr_b.pickup_otp,
    }, headers=headers)
    assert v_b.status_code == 200
    res_b = v_b.json()
    assert res_b["status"] == "PICKED_UP"
    assert res_b["all_picked_up"] is True

    db.refresh(pr_b)
    assert pr_b.status == "PICKED_UP"
