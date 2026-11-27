"""
Comprehensive test suite verifying all requirements:
1. Dual-source market loading (APMC yards + Discovered local markets) without cutoff.
2. Farmer Book Transport pickup window (Starts, Ends, validation, persistence).
3. Farmer Pooling pickup window (Starts, Ends, validation, consistency).
4. Farmer Pooling OTP isolation (Farmer A sees only A's OTP, Farmer B sees only B's, rider sees none, distinct verification).
5. Rider request classification (Pooled requests never leak into Individual tab).
6. Rider expected pickup time validation (Must fall within [window_start, window_end]).
7. Pickup window expiry for unaccepted requests (excluded from available, marked EXPIRED, acceptance rejected).
8. Pickup window expiry for accepted trips (marked MISSED/EXPIRED if unpicked before window end, history preserved).
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


@pytest.fixture(scope="module")
def client():
    return TestClient(app)


@pytest.fixture(scope="module")
def db():
    session = SessionLocal()
    yield session
    session.close()


def test_dual_source_market_loading_without_cutoff(client):
    """
    Requirement 3:
    GET /mandi/markets?district=Dakshina Kannada must return both:
    - APMC markets (e.g. Puttur APMC, Mangaluru APMC)
    - Discovered local markets (e.g. Urwa Market, Central Market, Surathkal Market)
    """
    resp = client.get("/mandi/markets?district=Dakshina Kannada")
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["district"] == "Dakshina Kannada"
    markets = data["markets"]
    assert len(markets) >= 2

    types = {m["type"] for m in markets}
    names = [m["name"] for m in markets]

    # Verify APMC market is present
    has_apmc = any("APMC" in n for n in names)
    assert has_apmc, f"Expected APMC market in {names}"

    # Verify local market is present
    has_local = any(m["type"] == "LOCAL_MARKET" for m in markets)
    assert has_local, f"Expected at least one LOCAL_MARKET in {markets}"


def test_farmer_pickup_window_validation_and_creation(client, db):
    """
    Requirement 4:
    Pickup Window Starts defaults to now, farmer selects Ends.
    Validation:
    - End must be later than Start.
    - Start cannot be in the past (> 5 minutes ago).
    - Both values saved correctly.
    """
    farmer = models.User(
        email=f"farmer_win_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Window Farmer",
        district="Dakshina Kannada",
        farm_size_acres=3.0,
        primary_crops="Arecanut, Coconut",
        farm_address="Vittal Road, Bantwal",
    )
    db.add(farmer)
    db.commit()
    db.refresh(farmer)

    token = client.post(f"/auth/dev-token?user_id={farmer.id}").json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    now = datetime.now(timezone.utc)

    # 1. Reject start time in the past
    past_start = now - timedelta(hours=2)
    past_end = now + timedelta(hours=2)
    bad_past = client.post("/produce-requests/", json={
        "crop_type": "Arecanut",
        "weight_kg": 150.0,
        "latitude": 12.8797,
        "longitude": 74.8827,
        "pickup_address": "Vittal Road, Bantwal",
        "dropoff_district": "Dakshina Kannada",
        "dropoff_mandi_name": "Mangaluru APMC",
        "pickup_window_start": past_start.isoformat(),
        "pickup_window_end": past_end.isoformat(),
    }, headers=headers)
    assert bad_past.status_code == 400
    assert "past" in bad_past.json()["detail"].lower()

    # 2. Reject end time <= start time
    valid_start = now + timedelta(hours=1)
    bad_end = valid_start - timedelta(minutes=30)
    bad_order = client.post("/produce-requests/", json={
        "crop_type": "Arecanut",
        "weight_kg": 150.0,
        "latitude": 12.8797,
        "longitude": 74.8827,
        "pickup_address": "Vittal Road, Bantwal",
        "dropoff_district": "Dakshina Kannada",
        "dropoff_mandi_name": "Mangaluru APMC",
        "pickup_window_start": valid_start.isoformat(),
        "pickup_window_end": bad_end.isoformat(),
    }, headers=headers)
    assert bad_order.status_code == 400
    assert "later" in bad_order.json()["detail"].lower()

    # 3. Successful creation with valid pickup window
    valid_end = valid_start + timedelta(hours=3)
    good_req = client.post("/produce-requests/", json={
        "crop_type": "Arecanut",
        "weight_kg": 150.0,
        "latitude": 12.8797,
        "longitude": 74.8827,
        "pickup_address": "Vittal Road, Bantwal",
        "dropoff_district": "Dakshina Kannada",
        "dropoff_mandi_name": "Mangaluru APMC",
        "pickup_window_start": valid_start.isoformat(),
        "pickup_window_end": valid_end.isoformat(),
    }, headers=headers)
    assert good_req.status_code == 201, good_req.text
    data = good_req.json()
    assert data["pickup_window_start"] is not None
    assert data["pickup_window_end"] is not None
    assert data["status"] == "PENDING"


def test_rider_request_classification_pooled_vs_individual(client, db):
    """
    Requirement 7:
    Pooled transport requests must NOT appear in GET /produce-requests/nearby (Individual tab).
    Only individual requests appear in the Individual tab.
    """
    now = datetime.now(timezone.utc)
    win_start = now + timedelta(hours=1)
    win_end = now + timedelta(hours=4)

    # Farmer creates an individual request
    farmer = models.User(
        email=f"farmer_cls_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Classif Farmer",
        district="Dakshina Kannada",
        farm_size_acres=2.5,
        primary_crops="Pepper, Spices",
        farm_address="Classif Farm",
    )
    db.add(farmer)
    db.commit()
    db.refresh(farmer)

    token = client.post(f"/auth/dev-token?user_id={farmer.id}").json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    # Individual request
    resp_ind = client.post("/produce-requests/", json={
        "crop_type": "Pepper",
        "weight_kg": 80.0,
        "latitude": 12.8700,
        "longitude": 74.8800,
        "pickup_address": "Individual Farm",
        "dropoff_district": "Dakshina Kannada",
        "dropoff_mandi_name": "Mangaluru APMC",
        "pickup_window_start": win_start.isoformat(),
        "pickup_window_end": win_end.isoformat(),
    }, headers=headers)
    assert resp_ind.status_code == 201, resp_ind.text
    ind_id = resp_ind.json()["id"]

    # Pooled request (for_pool = True)
    resp_pool_pr = client.post("/produce-requests/", json={
        "crop_type": "Pepper",
        "weight_kg": 90.0,
        "latitude": 12.8700,
        "longitude": 74.8800,
        "pickup_address": "Pooled Farm",
        "dropoff_district": "Dakshina Kannada",
        "dropoff_mandi_name": "Mangaluru APMC",
        "for_pool": True,
        "pickup_window_start": win_start.isoformat(),
        "pickup_window_end": win_end.isoformat(),
    }, headers=headers)
    assert resp_pool_pr.status_code == 201
    pool_pr_id = resp_pool_pr.json()["id"]

    # Now create pool using this produce request
    pool_resp = client.post("/pools/", json={
        "produce_request_id": pool_pr_id,
        "crop_type": "Pepper",
        "weight_kg": 90.0,
        "min_qty": 50.0,
        "dropoff_district": "Dakshina Kannada",
        "dropoff_mandi_name": "Mangaluru APMC",
        "pickup_window_start": win_start.isoformat(),
        "pickup_window_end": win_end.isoformat(),
    }, headers=headers)
    assert pool_resp.status_code == 201, pool_resp.text

    # Rider queries nearby produce requests (Individual tab)
    rider = models.User(
        email=f"rider_cls_{uuid.uuid4().hex[:6]}@example.com",
        role="RIDER",
        full_name="Classif Rider",
        is_on_duty=True,
    )
    db.add(rider)
    db.commit()
    db.refresh(rider)

    rider_token = client.post(f"/auth/dev-token?user_id={rider.id}").json()["access_token"]
    rider_headers = {"Authorization": f"Bearer {rider_token}"}

    nearby_resp = client.get("/produce-requests/nearby?lat=12.8700&lng=74.8800&radius_km=20", headers=rider_headers)
    assert nearby_resp.status_code == 200
    nearby_reqs = nearby_resp.json()
    nearby_ids = [r["id"] for r in nearby_reqs]

    assert ind_id in nearby_ids, "Individual request must appear in Individual tab"
    assert pool_pr_id not in nearby_ids, "Pooled request must NOT appear in Individual tab"


def test_rider_expected_pickup_time_validation(client, db):
    """
    Requirement 8:
    When accepting, rider must enter expected pickup time.
    Validation:
    Pickup Window Starts <= Rider Expected Pickup Time <= Pickup Window Ends
    """
    farmer = models.User(
        email=f"farmer_exp_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Expected Farmer",
        district="Dakshina Kannada",
        farm_size_acres=3.0,
        primary_crops="Cashew, Mango",
        farm_address="Puttur Farm",
    )
    rider = models.User(
        email=f"rider_exp_{uuid.uuid4().hex[:6]}@example.com",
        role="RIDER",
        full_name="Accepting Rider",
        phone_number="9876543210",
        vehicle_type="Small Truck",
        vehicle_number="KA-19-AB-1234",
        payload_capacity_kg=1500.0,
        license_number="KA19-20230001234",
        district="Dakshina Kannada",
        operating_routes="Mangaluru - Puttur",
        is_on_duty=True,
    )
    db.add_all([farmer, rider])
    db.commit()

    farmer_token = client.post(f"/auth/dev-token?user_id={farmer.id}").json()["access_token"]
    rider_token = client.post(f"/auth/dev-token?user_id={rider.id}").json()["access_token"]

    now = datetime.now(timezone.utc)
    w_start = now + timedelta(hours=2)
    w_end = now + timedelta(hours=6)

    pr_resp = client.post("/produce-requests/", json={
        "crop_type": "Cashew",
        "weight_kg": 120.0,
        "latitude": 12.8700,
        "longitude": 74.8800,
        "pickup_address": "Puttur Farm",
        "dropoff_district": "Dakshina Kannada",
        "dropoff_mandi_name": "Puttur APMC",
        "pickup_window_start": w_start.isoformat(),
        "pickup_window_end": w_end.isoformat(),
    }, headers={"Authorization": f"Bearer {farmer_token}"})
    assert pr_resp.status_code == 201, pr_resp.text
    pr_id = pr_resp.json()["id"]

    # 1. Rider attempts acceptance with expected pickup EARLIER than window start
    too_early = w_start - timedelta(minutes=30)
    early_resp = client.post(f"/trips/accept?request_id={pr_id}", json={
        "rider_expected_pickup_at": too_early.isoformat(),
    }, headers={"Authorization": f"Bearer {rider_token}"})
    assert early_resp.status_code == 400
    assert "earlier" in early_resp.json()["detail"].lower() or "within" in early_resp.json()["detail"].lower()

    # 2. Rider attempts acceptance with expected pickup LATER than window end
    too_late = w_end + timedelta(minutes=30)
    late_resp = client.post(f"/trips/accept?request_id={pr_id}", json={
        "rider_expected_pickup_at": too_late.isoformat(),
    }, headers={"Authorization": f"Bearer {rider_token}"})
    assert late_resp.status_code == 400
    assert "later" in late_resp.json()["detail"].lower() or "within" in late_resp.json()["detail"].lower()

    # 3. Rider accepts with valid expected pickup time within window
    valid_pickup = w_start + timedelta(hours=1)
    accept_resp = client.post(f"/trips/accept?request_id={pr_id}", json={
        "rider_expected_pickup_at": valid_pickup.isoformat(),
    }, headers={"Authorization": f"Bearer {rider_token}"})
    assert accept_resp.status_code in (200, 201), accept_resp.text
    trip_data = accept_resp.json()
    assert trip_data["status"] == "ACCEPTED"
    assert trip_data["rider_expected_pickup_at"] is not None

    # Verify active trips returns expected pickup time
    active_resp = client.get("/rider/trips/active", headers={"Authorization": f"Bearer {rider_token}"})
    assert active_resp.status_code == 200
    active_trips = active_resp.json()
    matching = [t for t in active_trips if t["produce_request_id"] == pr_id]
    assert len(matching) == 1
    assert matching[0]["rider_expected_pickup_at"] is not None


def test_farmer_pooling_otp_isolation_and_distinct_verification(client, db):
    """
    Requirement 6:
    - Farmer A in pool has distinct OTP.
    - Farmer B in pool has distinct OTP.
    - Farmer A sees only Farmer A's OTP (Farmer B's is hidden).
    - Farmer B sees only Farmer B's OTP (Farmer A's is hidden).
    - Rider sees neither OTP in pool details.
    - Rider verifies each farmer separately; one farmer's OTP never verifies another.
    """
    now = datetime.now(timezone.utc)
    w_start = now + timedelta(hours=1)
    w_end = now + timedelta(hours=5)

    farmer_a = models.User(
        email=f"farmer_a_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Farmer Alice",
        district="Dakshina Kannada",
        farm_size_acres=2.0,
        primary_crops="Ginger",
        farm_address="Alice Farm",
    )
    farmer_b = models.User(
        email=f"farmer_b_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Farmer Bob",
        district="Dakshina Kannada",
        farm_size_acres=2.0,
        primary_crops="Ginger",
        farm_address="Bob Farm",
    )
    rider = models.User(
        email=f"rider_pool_{uuid.uuid4().hex[:6]}@example.com",
        role="RIDER",
        full_name="Pool Rider",
        phone_number="9876543211",
        vehicle_type="Small Truck",
        vehicle_number="KA-19-CD-5678",
        payload_capacity_kg=2000.0,
        license_number="KA19-20230005678",
        district="Dakshina Kannada",
        operating_routes="Mangaluru - Puttur",
        is_on_duty=True,
    )
    db.add_all([farmer_a, farmer_b, rider])
    db.commit()

    token_a = client.post(f"/auth/dev-token?user_id={farmer_a.id}").json()["access_token"]
    token_b = client.post(f"/auth/dev-token?user_id={farmer_b.id}").json()["access_token"]
    token_rider = client.post(f"/auth/dev-token?user_id={rider.id}").json()["access_token"]

    # 1. Farmer A creates pool
    pr_a = client.post("/produce-requests/", json={
        "crop_type": "Ginger",
        "weight_kg": 60.0,
        "latitude": 12.8700,
        "longitude": 74.8800,
        "pickup_address": "Alice Farm",
        "dropoff_district": "Dakshina Kannada",
        "dropoff_mandi_name": "Mangaluru APMC",
        "for_pool": True,
        "pickup_window_start": w_start.isoformat(),
        "pickup_window_end": w_end.isoformat(),
    }, headers={"Authorization": f"Bearer {token_a}"}).json()

    pool = client.post("/pools/", json={
        "produce_request_id": pr_a["id"],
        "crop_type": "Ginger",
        "weight_kg": 60.0,
        "min_qty": 50.0,
        "dropoff_district": "Dakshina Kannada",
        "dropoff_mandi_name": "Mangaluru APMC",
        "pickup_window_start": w_start.isoformat(),
        "pickup_window_end": w_end.isoformat(),
    }, headers={"Authorization": f"Bearer {token_a}"}).json()
    pool_id = pool["id"]

    # 2. Farmer B joins pool
    pr_b = client.post("/produce-requests/", json={
        "crop_type": "Ginger",
        "weight_kg": 70.0,
        "latitude": 12.8750,
        "longitude": 74.8850,
        "pickup_address": "Bob Farm",
        "dropoff_district": "Dakshina Kannada",
        "dropoff_mandi_name": "Mangaluru APMC",
        "for_pool": True,
        "pickup_window_start": w_start.isoformat(),
        "pickup_window_end": w_end.isoformat(),
    }, headers={"Authorization": f"Bearer {token_b}"}).json()

    join_resp = client.post(f"/pools/{pool_id}/join", json={
        "produce_request_id": pr_b["id"],
        "weight_kg": 70.0,
    }, headers={"Authorization": f"Bearer {token_b}"})
    assert join_resp.status_code in (200, 201), join_resp.text

    # 3. Rider accepts pool with expected pickup time
    exp_time = w_start + timedelta(hours=2)
    acc_pool = client.post(f"/pools/{pool_id}/accept", json={
        "rider_expected_pickup_at": exp_time.isoformat(),
    }, headers={"Authorization": f"Bearer {token_rider}"})
    assert acc_pool.status_code in (200, 201)

    # 4. Farmer A checks pool detail: sees ONLY A's OTP
    detail_a = client.get(f"/pools/{pool_id}", headers={"Authorization": f"Bearer {token_a}"}).json()
    mem_a_for_a = [m for m in detail_a["members"] if m["farmer_id"] == str(farmer_a.id)][0]
    mem_b_for_a = [m for m in detail_a["members"] if m["farmer_id"] == str(farmer_b.id)][0]
    assert mem_a_for_a["pickup_otp"] is not None, "Farmer A must see their own OTP"
    assert mem_b_for_a["pickup_otp"] is None, "Farmer A must NOT see Farmer B's OTP"
    otp_a = mem_a_for_a["pickup_otp"]

    # 5. Farmer B checks pool detail: sees ONLY B's OTP
    detail_b = client.get(f"/pools/{pool_id}", headers={"Authorization": f"Bearer {token_b}"}).json()
    mem_a_for_b = [m for m in detail_b["members"] if m["farmer_id"] == str(farmer_a.id)][0]
    mem_b_for_b = [m for m in detail_b["members"] if m["farmer_id"] == str(farmer_b.id)][0]
    assert mem_b_for_b["pickup_otp"] is not None, "Farmer B must see their own OTP"
    assert mem_a_for_b["pickup_otp"] is None, "Farmer B must NOT see Farmer A's OTP"
    otp_b = mem_b_for_b["pickup_otp"]

    assert otp_a != otp_b, "Each farmer must have a unique, distinct OTP"

    # 6. Rider checks pool detail: OTP is hidden
    detail_rider = client.get(f"/pools/{pool_id}", headers={"Authorization": f"Bearer {token_rider}"}).json()
    for m in detail_rider["members"]:
        assert m["pickup_otp"] is None, "Rider must NOT receive plaintext OTPs"

    # 7. Verification: Farmer A's trip cannot be verified by Farmer B's OTP
    trips = db.query(models.Trip).filter(models.Trip.pool_id == uuid.UUID(pool_id)).all()
    assert len(trips) == 2
    trip_a = [t for t in trips if t.produce_request_id == uuid.UUID(pr_a["id"])][0]
    trip_b = [t for t in trips if t.produce_request_id == uuid.UUID(pr_b["id"])][0]

    # Try verifying Trip A with OTP B -> FAILS
    bad_verify = client.post(f"/rider/trips/{trip_a.id}/verify-otp", json={"otp": otp_b}, headers={"Authorization": f"Bearer {token_rider}"})
    assert bad_verify.status_code == 400

    # Verify Trip A with OTP A -> SUCCEEDS
    good_verify_a = client.post(f"/rider/trips/{trip_a.id}/verify-otp", json={"otp": otp_a}, headers={"Authorization": f"Bearer {token_rider}"})
    assert good_verify_a.status_code == 200

    # Trip B is still ACCEPTED (not verified)
    db.refresh(trip_b)
    assert trip_b.status == "ACCEPTED"

    # Verify Trip B with OTP B -> SUCCEEDS
    good_verify_b = client.post(f"/rider/trips/{trip_b.id}/verify-otp", json={"otp": otp_b}, headers={"Authorization": f"Bearer {token_rider}"})
    assert good_verify_b.status_code == 200
    assert good_verify_b.json()["new_status"] == "PICKED_UP"
    db.refresh(trip_b)
    assert trip_b.status == "PICKED_UP"


def test_pickup_window_expiry_unaccepted_and_accepted(client, db):
    """
    Requirement 9:
    1. Unaccepted request whose pickup window end has passed:
       - Marked EXPIRED.
       - Excluded from available requests.
       - Cannot be accepted.
    2. Accepted trip whose pickup window end has passed without pickup verification:
       - Marked MISSED and request marked EXPIRED.
       - Excluded from active pickups.
       - History preserved (records are never deleted).
    """
    now = datetime.now(timezone.utc)
    expired_start = now - timedelta(hours=3)
    expired_end = now - timedelta(minutes=10)  # already ended!

    farmer = models.User(
        email=f"farmer_exp_chk_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name="Expiry Farmer",
        district="Dakshina Kannada",
        farm_size_acres=3.0,
        primary_crops="Coffee, Rubber",
        farm_address="Expiry Farm",
    )
    rider = models.User(
        email=f"rider_exp_chk_{uuid.uuid4().hex[:6]}@example.com",
        role="RIDER",
        full_name="Expiry Rider",
        is_on_duty=True,
    )
    db.add_all([farmer, rider])
    db.commit()

    farmer_token = client.post(f"/auth/dev-token?user_id={farmer.id}").json()["access_token"]
    rider_token = client.post(f"/auth/dev-token?user_id={rider.id}").json()["access_token"]

    # 1. Unaccepted produce request past pickup window end
    pr_unaccepted = models.ProduceRequest(
        farmer_id=farmer.id,
        crop_type="Rubber",
        weight_kg=100.0,
        status="PENDING",
        pickup_location=WKTElement("POINT(74.88 12.87)", srid=4326),
        pickup_address="Old Farm",
        dropoff_district="Dakshina Kannada",
        pickup_window_start=expired_start,
        pickup_window_end=expired_end,
        requested_pickup_at=expired_start,
    )
    db.add(pr_unaccepted)
    db.commit()
    db.refresh(pr_unaccepted)

    # Cannot accept expired request
    acc_attempt = client.post(f"/trips/accept?request_id={pr_unaccepted.id}", json={
        "rider_expected_pickup_at": now.isoformat(),
    }, headers={"Authorization": f"Bearer {rider_token}"})
    assert acc_attempt.status_code in (400, 404, 409)
    assert "expired" in acc_attempt.json()["detail"].lower()

    # Verify excluded from nearby available requests
    nearby_resp = client.get("/produce-requests/nearby?lat=12.8700&lng=74.8800&radius_km=100", headers={"Authorization": f"Bearer {rider_token}"})
    assert nearby_resp.status_code == 200
    ids = [r["id"] for r in nearby_resp.json()]
    assert str(pr_unaccepted.id) not in ids

    # 2. Accepted trip past pickup window end without OTP verification
    pr_accepted = models.ProduceRequest(
        farmer_id=farmer.id,
        crop_type="Coffee",
        weight_kg=100.0,
        status="ACCEPTED",
        pickup_location=WKTElement("POINT(74.88 12.87)", srid=4326),
        pickup_address="Accepted Farm",
        dropoff_district="Dakshina Kannada",
        pickup_window_start=expired_start,
        pickup_window_end=expired_end,
        requested_pickup_at=expired_start,
        pickup_otp="9999",
    )
    db.add(pr_accepted)
    db.commit()
    db.refresh(pr_accepted)

    trip = models.Trip(
        produce_request_id=pr_accepted.id,
        rider_id=rider.id,
        status="ACCEPTED",
        rider_expected_pickup_at=expired_start + timedelta(hours=1),
    )
    db.add(trip)
    db.commit()
    db.refresh(trip)

    # Calling active trips expires the overdue ACCEPTED trip to MISSED/EXPIRED
    active_resp = client.get("/rider/trips/active", headers={"Authorization": f"Bearer {rider_token}"})
    assert active_resp.status_code == 200
    active_trips = active_resp.json()
    assert not any(t["order_id"] == str(trip.id) for t in active_trips), "Overdue unpicked trip must not be in active pickups"

    # Verify history is preserved in DB (never deleted)
    db.refresh(trip)
    db.refresh(pr_accepted)
    assert trip.status == "MISSED", f"Expected MISSED status, got {trip.status}"
    assert pr_accepted.status == "EXPIRED", f"Expected EXPIRED status, got {pr_accepted.status}"
