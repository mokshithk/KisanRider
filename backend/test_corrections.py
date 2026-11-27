"""
Integration and regression test suite for KisanRider corrections:
1. District market loading performance and caching
2. Farmer profile completeness enforcement (Farm details + Saved address)
3. Requested pickup date/time in UTC, validation, and zero-grace-period expiry
4. Rider profile completeness enforcement for On-Duty and acceptance
5. Vehicle payload capacity validation
6. Pool route optimization (OR-Tools + OSRM road geometry)
7. Bank and UPI details remaining optional for both Farmer and Rider
"""

import uuid
from datetime import datetime, timedelta, timezone
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

from database import SessionLocal
from main import app
import models
import schemas
from pools import models as pool_models

client = TestClient(app)


def test_market_loading_and_caching():
    """Verify dual-source market loading, performance, and 24h caching."""
    resp1 = client.get("/mandi/markets", params={"district": "Dakshina Kannada"})
    assert resp1.status_code == 200, resp1.text
    data1 = resp1.json()
    assert "markets" in data1
    assert data1["district"] == "Dakshina Kannada"
    assert len(data1["markets"]) > 0

    # Second call should be instantaneous from cache
    start_time = datetime.now()
    resp2 = client.get("/mandi/markets", params={"district": "Dakshina Kannada"})
    elapsed = (datetime.now() - start_time).total_seconds()
    assert resp2.status_code == 200
    assert elapsed < 0.2, f"Expected cache hit < 0.2s, got {elapsed}s"


def test_farmer_booking_profile_completion_and_pickup_validation():
    """Verify Farm Details & Saved Address are mandatory, while Bank/UPI is optional."""
    db = SessionLocal()
    unique_suffix = uuid.uuid4().hex[:8]
    farmer_email = f"farmer_test_{unique_suffix}@example.com"

    try:
        # Create a farmer with incomplete profile (no farm details, no saved addresses)
        farmer = models.User(
            email=farmer_email,
            full_name=f"Test Farmer {unique_suffix}",
            role="FARMER",
            is_active=True,
            is_verified=True,
            farm_size_acres=None,  # Missing
            primary_crops=None,    # Missing
        )
        db.add(farmer)
        db.commit()
        db.refresh(farmer)

        import auth
        token = auth.create_access_token(farmer.id)
        headers = {"Authorization": f"Bearer {token}"}

        future_pickup = (datetime.now(timezone.utc) + timedelta(days=2)).isoformat()
        past_pickup = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()

        req_payload = {
            "crop_type": "Tomatoes",
            "weight_kg": 50.0,
            "latitude": 12.9141,
            "longitude": 74.8560,
            "pickup_address": "Test Farm, Mangaluru",
            "dropoff_district": "Dakshina Kannada",
            "dropoff_mandi_name": "Mangaluru APMC",
            "requested_pickup_at": future_pickup,
        }

        # 1. Attempt to book transport with incomplete Farm Details
        resp = client.post("/farmer/orders/create", json=req_payload, headers=headers)
        assert resp.status_code == 400
        assert "Farm Details incomplete" in resp.json()["detail"]

        # 2. Update farm details, but still no saved address
        farmer.farm_size_acres = 5.0
        farmer.primary_crops = "Tomatoes, Chilies"
        db.commit()

        resp = client.post("/farmer/orders/create", json=req_payload, headers=headers)
        assert resp.status_code == 400
        assert "Saved Farm Addresses missing" in resp.json()["detail"]

        # 3. Add saved address
        saved_addr = models.SavedAddress(
            farmer_id=farmer.id,
            title="Home Farm",
            address_text="Bendoor, Mangaluru",
            latitude=12.9141,
            longitude=74.8560,
        )
        db.add(saved_addr)
        db.commit()

        # 4. Attempt with past date/time -> Should be rejected
        past_payload = dict(req_payload)
        past_payload["requested_pickup_at"] = past_pickup
        resp_past = client.post("/farmer/orders/create", json=past_payload, headers=headers)
        assert resp_past.status_code == 400
        assert "must be in the future" in resp_past.json()["detail"]

        # 5. Successfully book transport with complete profile (and no banking/UPI required!)
        resp_ok = client.post("/farmer/orders/create", json=req_payload, headers=headers)
        assert resp_ok.status_code == 201, resp_ok.text
        created_order = resp_ok.json()
        assert created_order["status"] == "PENDING"
        assert created_order["requested_pickup_at"] is not None

    finally:
        db.close()


def test_rider_profile_completion_and_duty_status():
    """Verify Rider must complete vehicle, license, and operating routes before On-Duty."""
    db = SessionLocal()
    unique_suffix = uuid.uuid4().hex[:8]
    rider_email = f"rider_test_{unique_suffix}@example.com"

    try:
        # Create rider with missing vehicle info
        rider = models.User(
            email=rider_email,
            full_name=f"Test Rider {unique_suffix}",
            phone_number="9876543210",
            role="RIDER",
            is_active=True,
            is_verified=True,
            is_on_duty=False,
            vehicle_type=None,
            vehicle_number=None,
            payload_capacity_kg=None,
            license_number=None,
        )
        db.add(rider)
        db.commit()
        db.refresh(rider)

        import auth
        token = auth.create_access_token(rider.id)
        headers = {"Authorization": f"Bearer {token}"}

        # 1. Attempt to go On-Duty without profile details -> Should be rejected
        resp_duty = client.patch("/rider/duty-status", json={"is_on_duty": True}, headers=headers)
        assert resp_duty.status_code == 400
        detail = resp_duty.json()["detail"]
        assert "Please complete your profile before going On-Duty" in detail

        # 2. Fill vehicle, license, and operating district/routes (leave bank/UPI empty!)
        rider.vehicle_type = "Mini Truck (Tata Ace)"
        rider.vehicle_number = "KA-19-AB-1234"
        rider.payload_capacity_kg = 750.0
        rider.license_number = "DL-1920240012345"
        rider.district = "Dakshina Kannada"
        rider.operating_routes = "Mangaluru - Bantwal - Puttur"
        db.commit()

        # 3. Now toggle On-Duty -> Should succeed
        resp_duty_ok = client.patch("/rider/duty-status", json={"is_on_duty": True}, headers=headers)
        assert resp_duty_ok.status_code == 200
        assert resp_duty_ok.json()["is_on_duty"] is True

    finally:
        db.close()


def test_request_expiry_and_capacity_validation_on_accept():
    """Verify zero grace period expiry and vehicle payload capacity on accept."""
    db = SessionLocal()
    unique_suffix = uuid.uuid4().hex[:8]

    try:
        import auth
        # Create complete rider with 100 kg capacity
        rider = models.User(
            email=f"rider_cap_{unique_suffix}@example.com",
            full_name=f"Capacity Rider {unique_suffix}",
            phone_number="9876543211",
            role="RIDER",
            is_active=True,
            is_verified=True,
            is_on_duty=True,
            vehicle_type="Small Pickup",
            vehicle_number="KA-19-CD-5678",
            payload_capacity_kg=100.0,
            license_number="DL-1920240099999",
            district="Dakshina Kannada",
            operating_routes="Mangaluru - Udupi",
        )
        db.add(rider)
        db.commit()
        db.refresh(rider)

        token = auth.create_access_token(rider.id)
        headers = {"Authorization": f"Bearer {token}"}

        # Create farmer
        farmer = models.User(
            email=f"farmer_cap_{unique_suffix}@example.com",
            full_name=f"Farmer {unique_suffix}",
            role="FARMER",
            is_active=True,
            is_verified=True,
            farm_size_acres=3.0,
            primary_crops="Tomatoes",
        )
        db.add(farmer)
        db.commit()
        db.refresh(farmer)

        # 1. Request with weight exceeding rider capacity (150 kg > 100 kg)
        from geoalchemy2.elements import WKTElement
        pr_heavy = models.ProduceRequest(
            farmer_id=farmer.id,
            crop_type="Tomatoes",
            weight_kg=150.0,
            pickup_location=WKTElement("POINT(74.8560 12.9141)", srid=4326),
            pickup_address="Farm Gate",
            dropoff_district="Dakshina Kannada",
            dropoff_mandi_name="Mangaluru APMC",
            status="PENDING",
            requested_pickup_at=datetime.now(timezone.utc) + timedelta(days=1),
        )
        db.add(pr_heavy)

        # 2. Request that has already expired
        pr_expired = models.ProduceRequest(
            farmer_id=farmer.id,
            crop_type="Tomatoes",
            weight_kg=50.0,
            pickup_location=WKTElement("POINT(74.8560 12.9141)", srid=4326),
            pickup_address="Farm Gate",
            dropoff_district="Dakshina Kannada",
            dropoff_mandi_name="Mangaluru APMC",
            status="PENDING",
            requested_pickup_at=datetime.now(timezone.utc) - timedelta(minutes=5),
        )
        db.add(pr_expired)
        db.commit()
        db.refresh(pr_heavy)
        db.refresh(pr_expired)

        # A. Heavy request acceptance -> Should fail on vehicle capacity
        resp_heavy = client.post(f"/trips/accept?request_id={pr_heavy.id}", headers=headers)
        assert resp_heavy.status_code == 400
        assert "exceeds your vehicle capacity" in resp_heavy.json()["detail"]

        # B. Expired request acceptance -> Should fail on zero-grace-period expiry
        resp_exp = client.post(f"/trips/accept?request_id={pr_expired.id}", headers=headers)
        assert resp_exp.status_code == 400
        assert "expired and cannot be accepted" in resp_exp.json()["detail"]

        # Verify expired request status was atomically updated to EXPIRED in DB
        db.refresh(pr_expired)
        assert pr_expired.status == "EXPIRED"

    finally:
        db.close()


def test_pool_route_optimization():
    """Verify route optimization endpoint returns ordered stops and road geometry."""
    db = SessionLocal()
    unique_suffix = uuid.uuid4().hex[:8]

    try:
        import auth
        # Create farmer creator
        farmer = models.User(
            email=f"pool_farmer_{unique_suffix}@example.com",
            full_name=f"Pool Farmer {unique_suffix}",
            role="FARMER",
            is_active=True,
            is_verified=True,
            farm_size_acres=5.0,
            primary_crops="Tomatoes",
        )
        db.add(farmer)
        db.commit()
        db.refresh(farmer)

        from geoalchemy2.elements import WKTElement
        pr = models.ProduceRequest(
            farmer_id=farmer.id,
            crop_type="Tomatoes",
            weight_kg=80.0,
            pickup_location=WKTElement("POINT(74.8450 12.8710)", srid=4326),
            pickup_address="Bendoor Farm, Mangaluru",
            dropoff_district="Dakshina Kannada",
            dropoff_mandi_name="Mangaluru APMC",
            dropoff_lat=12.9141,
            dropoff_lng=74.8560,
            status="PENDING",
            requested_pickup_at=datetime.now(timezone.utc) + timedelta(days=2),
        )
        db.add(pr)
        db.commit()
        db.refresh(pr)

        # Create pool
        pool = pool_models.Pool(
            creator_id=farmer.id,
            crop_type="Tomatoes",
            dropoff_district="Dakshina Kannada",
            dropoff_mandi_name="Mangaluru APMC",
            pickup_window_start=datetime.now(timezone.utc) + timedelta(days=1),
            pickup_window_end=datetime.now(timezone.utc) + timedelta(days=2),
            min_qty=50.0,
            max_qty=500.0,
            current_qty=80.0,
            status=pool_models.PoolStatus.OPEN.value,
        )
        db.add(pool)
        db.commit()
        db.refresh(pool)

        # Add member
        member = pool_models.PoolMember(
            pool_id=pool.id,
            farmer_id=farmer.id,
            produce_request_id=pr.id,
            weight_kg=80.0,
            status=pool_models.PoolMemberStatus.ACCEPTED.value,
        )
        db.add(member)
        db.commit()

        # Create rider
        rider = models.User(
            email=f"pool_rider_{unique_suffix}@example.com",
            full_name="Pool Rider",
            role="RIDER",
            is_active=True,
            is_verified=True,
        )
        db.add(rider)
        db.commit()
        db.refresh(rider)

        token = auth.create_access_token(rider.id)
        headers = {"Authorization": f"Bearer {token}"}

        resp = client.get(
            f"/pools/{pool.id}/route-optimization",
            params={"rider_lat": 12.8600, "rider_lng": 74.8350},
            headers=headers,
        )
        assert resp.status_code == 200, resp.text
        data = resp.json()
        assert data["pool_id"] == str(pool.id)
        assert "ordered_stops" in data
        assert len(data["ordered_stops"]) == 1
        assert "route_geometry" in data
        assert data["total_distance_km"] > 0
        assert data["routing_status"] in ("OPTIMIZED", "APPROXIMATED")

    finally:
        db.close()
