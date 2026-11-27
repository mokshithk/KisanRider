"""
Verification tests for:
1. Individual produce requests remaining visible in GET /produce-requests/nearby
   throughout the active pickup window (even after pickup_window_start /
   requested_pickup_at has started, until pickup_window_end expires).
2. Complete pool delivery workflow:
   - Uploading delivery proof photo via POST /uploads/delivery-photo
   - Enforcing OTP completion & photo requirement & rider ownership on POST /pools/{id}/deliver
   - Marking all pool Trips as DELIVERED, ProduceRequests as COMPLETED, Pool as COMPLETED
   - Auto-creating Settlement rows for every farmer in the pool
   - Preserving driver info and pool visibility for farmers on /pools/my, /pools/{id},
     /produce-requests/farmer/me, /farmer/orders/{id}, /settlements/me, and /rider/trips/history.
"""

import os
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from database import SessionLocal
from main import app
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


def _create_farmer(db, suffix: str, name: str):
    u = models.User(
        email=f"farmer_{suffix}_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name=name,
        phone_number="9845000001",
        district="Dakshina Kannada",
        farm_size_acres=3.0,
        primary_crops="Arecanut, Tomatoes",
        farm_address="Puttur Farm Gate",
    )
    db.add(u)
    db.commit()
    db.refresh(u)
    return u


def _create_rider(db, suffix: str, name: str):
    u = models.User(
        email=f"rider_{suffix}_{uuid.uuid4().hex[:6]}@example.com",
        role="RIDER",
        full_name=name,
        phone_number="9845000099",
        vehicle_type="Mini Truck",
        vehicle_number="KA-19-ZZ-9999",
        payload_capacity_kg=2000.0,
        license_number="KA19-20240009999",
        district="Dakshina Kannada",
        operating_routes="Puttur - Bantwal - Mangaluru",
        is_on_duty=True,
    )
    db.add(u)
    db.commit()
    db.refresh(u)
    return u


def test_individual_request_visible_during_active_pickup_window(client, db):
    """
    When a farmer submits an individual request whose pickup window starts NOW
    (or up to 4 minutes ago, as happens when Farmer Book Transport defaults
    to current DateTime and requested_pickup_at = win_start), the request MUST
    appear in GET /produce-requests/nearby until pickup_window_end passes.
    """
    farmer = _create_farmer(db, "ind_win", "Individual Window Farmer")
    rider = _create_rider(db, "ind_win", "Individual Window Rider")

    f_token = client.post(f"/auth/dev-token?user_id={farmer.id}").json()["access_token"]
    r_token = client.post(f"/auth/dev-token?user_id={rider.id}").json()["access_token"]
    f_headers = {"Authorization": f"Bearer {f_token}"}
    r_headers = {"Authorization": f"Bearer {r_token}"}

    now = datetime.now(timezone.utc)
    started_recently = now - timedelta(minutes=2)
    ends_later = now + timedelta(hours=6)

    resp = client.post(
        "/produce-requests/",
        json={
            "crop_type": "Arecanut",
            "weight_kg": 200.0,
            "latitude": 12.9617,
            "longitude": 75.1910,
            "pickup_address": "12.9617, 75.1910",
            "dropoff_district": "Dakshina Kannada",
            "dropoff_mandi_name": "Bantwala APMC",
            "requested_pickup_at": started_recently.isoformat(),
            "pickup_window_start": started_recently.isoformat(),
            "pickup_window_end": ends_later.isoformat(),
        },
        headers=f_headers,
    )
    assert resp.status_code == 201, resp.text
    active_id = resp.json()["id"]

    # Expired window should still be excluded
    expired_pr = models.ProduceRequest(
        farmer_id=farmer.id,
        crop_type="Old Crop",
        weight_kg=50.0,
        status="PENDING",
        pickup_address="Expired Farm",
        dropoff_district="Dakshina Kannada",
        pickup_window_start=now - timedelta(hours=5),
        pickup_window_end=now - timedelta(minutes=1),
        requested_pickup_at=now - timedelta(hours=5),
        pickup_location="SRID=4326;POINT(75.1910 12.9617)",
    )
    db.add(expired_pr)
    db.commit()
    db.refresh(expired_pr)

    nearby = client.get(
        "/produce-requests/nearby?lat=12.9617&lng=75.1910&radius_km=50",
        headers=r_headers,
    )
    assert nearby.status_code == 200, nearby.text
    ids = [item["id"] for item in nearby.json()]

    assert active_id in ids, "Active individual request must appear in rider nearby dashboard"
    assert str(expired_pr.id) not in ids, "Expired individual request must be excluded"

    # Verify rider can accept the active request (even with minute-rounded arrival near win_start)
    acc = client.post(
        f"/trips/accept?request_id={active_id}",
        json={"rider_expected_pickup_at": (now + timedelta(minutes=10)).isoformat()},
        headers=r_headers,
    )
    assert acc.status_code in (200, 201), acc.text
    assert acc.json()["status"] == "ACCEPTED"


def test_pool_delivery_with_proof_image_and_farmer_status(client, db):
    """
    End-to-end test for pooled delivery:
    - Farmers A & B form a pool and rider accepts it.
    - Deliver fails before all stops are OTP-verified.
    - Both stops are OTP-verified -> all_picked_up == True.
    - Wrong rider cannot deliver pool (403).
    - Uploading proof image + calling POST /pools/{id}/deliver transitions:
      * Pool -> COMPLETED
      * Both Trips -> DELIVERED with completed_at
      * Both ProduceRequests -> COMPLETED
      * Both Settlements created
      * Farmer views (/produce-requests/farmer/me, /farmer/orders/{id}, /pools/my, /pools/{id})
        reflect completion/delivered status and preserve driver info.
    """
    farmer_a = _create_farmer(db, "pool_del_a", "Pool Farmer A")
    farmer_b = _create_farmer(db, "pool_del_b", "Pool Farmer B")
    rider = _create_rider(db, "pool_del_r", "Pool Rider Main")
    other_rider = _create_rider(db, "pool_del_other", "Other Rider")

    tok_a = client.post(f"/auth/dev-token?user_id={farmer_a.id}").json()["access_token"]
    tok_b = client.post(f"/auth/dev-token?user_id={farmer_b.id}").json()["access_token"]
    tok_r = client.post(f"/auth/dev-token?user_id={rider.id}").json()["access_token"]
    tok_other = client.post(f"/auth/dev-token?user_id={other_rider.id}").json()["access_token"]

    h_a = {"Authorization": f"Bearer {tok_a}"}
    h_b = {"Authorization": f"Bearer {tok_b}"}
    h_r = {"Authorization": f"Bearer {tok_r}"}
    h_other = {"Authorization": f"Bearer {tok_other}"}

    now = datetime.now(timezone.utc)
    w_start = now - timedelta(minutes=1)
    w_end = now + timedelta(hours=8)

    # 1. Farmer A creates request + pool
    pr_a = client.post(
        "/produce-requests/",
        json={
            "crop_type": "Tomatoes",
            "weight_kg": 120.0,
            "latitude": 12.9617,
            "longitude": 75.1910,
            "pickup_address": "Farm A",
            "dropoff_district": "Dakshina Kannada",
            "dropoff_mandi_name": "Bantwala APMC",
            "for_pool": True,
            "pickup_window_start": w_start.isoformat(),
            "pickup_window_end": w_end.isoformat(),
        },
        headers=h_a,
    ).json()

    pool = client.post(
        "/pools/",
        json={
            "produce_request_id": pr_a["id"],
            "crop_type": "Tomatoes",
            "weight_kg": 120.0,
            "min_qty": 50.0,
            "dropoff_district": "Dakshina Kannada",
            "dropoff_mandi_name": "Bantwala APMC",
            "pickup_window_start": w_start.isoformat(),
            "pickup_window_end": w_end.isoformat(),
        },
        headers=h_a,
    ).json()
    pool_id = pool["id"]

    # 2. Farmer B creates request + joins pool
    pr_b = client.post(
        "/produce-requests/",
        json={
            "crop_type": "Tomatoes",
            "weight_kg": 80.0,
            "latitude": 12.9650,
            "longitude": 75.1950,
            "pickup_address": "Farm B",
            "dropoff_district": "Dakshina Kannada",
            "dropoff_mandi_name": "Bantwala APMC",
            "for_pool": True,
        },
        headers=h_b,
    ).json()

    join_resp = client.post(
        f"/pools/{pool_id}/join",
        json={"produce_request_id": pr_b["id"], "weight_kg": 80.0},
        headers=h_b,
    )
    assert join_resp.status_code == 200, join_resp.text

    # 3. Rider accepts pool
    acc_resp = client.post(
        f"/pools/{pool_id}/accept",
        json={"rider_expected_pickup_at": (now + timedelta(minutes=15)).isoformat()},
        headers=h_r,
    )
    assert acc_resp.status_code in (200, 201), acc_resp.text

    # Fetch OTPs from farmer endpoints
    det_a = client.get(f"/pools/{pool_id}", headers=h_a).json()
    det_b = client.get(f"/pools/{pool_id}", headers=h_b).json()
    otp_a = next(m["pickup_otp"] for m in det_a["members"] if m["farmer_id"] == str(farmer_a.id))
    otp_b = next(m["pickup_otp"] for m in det_b["members"] if m["farmer_id"] == str(farmer_b.id))

    # 4. Upload a tiny valid PNG proof photo
    tiny_png = (
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
        b"\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc```\x00\x00"
        b"\x00\x04\x00\x01\xf6\x178U\x00\x00\x00\x00IEND\xaeB`\x82"
    )
    up_resp = client.post(
        "/uploads/delivery-photo",
        files={"file": ("proof.png", tiny_png, "image/png")},
        headers=h_r,
    )
    assert up_resp.status_code in (200, 201), up_resp.text
    photo_url = up_resp.json()["image_url"]
    assert photo_url.startswith("/static/uploads/")

    try:
        # 5. Cannot deliver before OTP verification
        pre_del = client.post(
            f"/pools/{pool_id}/deliver",
            json={"delivery_photo_url": photo_url},
            headers=h_r,
        )
        assert pre_del.status_code == 400
        assert "otp" in pre_del.json()["detail"].lower()

        # Verify OTP for Farmer A only -> still cannot deliver
        v_a = client.post(
            f"/pools/{pool_id}/verify-farmer-otp",
            json={"produce_request_id": pr_a["id"], "otp": otp_a},
            headers=h_r,
        )
        assert v_a.status_code == 200
        assert v_a.json()["all_picked_up"] is False

        mid_del = client.post(
            f"/pools/{pool_id}/deliver",
            json={"delivery_photo_url": photo_url},
            headers=h_r,
        )
        assert mid_del.status_code == 400

        # Verify OTP for Farmer B -> all_picked_up becomes True
        v_b = client.post(
            f"/pools/{pool_id}/verify-farmer-otp",
            json={"produce_request_id": pr_b["id"], "otp": otp_b},
            headers=h_r,
        )
        assert v_b.status_code == 200
        assert v_b.json()["all_picked_up"] is True

        # Wrong rider rejected with 403
        wrong_del = client.post(
            f"/pools/{pool_id}/deliver",
            json={"delivery_photo_url": photo_url},
            headers=h_other,
        )
        assert wrong_del.status_code == 403

        # Missing photo URL rejected
        no_photo = client.post(
            f"/pools/{pool_id}/deliver",
            json={"delivery_photo_url": ""},
            headers=h_r,
        )
        assert no_photo.status_code in (400, 422)

        # 6. Assigned rider delivers pool with proof photo
        del_resp = client.post(
            f"/pools/{pool_id}/deliver",
            json={"delivery_photo_url": photo_url, "distance_km": 14.5},
            headers=h_r,
        )
        assert del_resp.status_code == 200, del_resp.text
        del_data = del_resp.json()
        assert del_data["success"] is True
        assert del_data["pool_status"] == "COMPLETED"
        assert del_data["trips_delivered"] == 2
        assert del_data["delivery_photo_url"] == photo_url

        # Double delivery rejected cleanly
        dup_del = client.post(
            f"/pools/{pool_id}/deliver",
            json={"delivery_photo_url": photo_url},
            headers=h_r,
        )
        assert dup_del.status_code == 400

        # 7. Verify farmer side matches individual delivered flow
        for tok, pid, fid in [(h_a, pr_a["id"], farmer_a.id), (h_b, pr_b["id"], farmer_b.id)]:
            me_reqs = client.get("/produce-requests/farmer/me", headers=tok)
            assert me_reqs.status_code == 200
            matched = [r for r in me_reqs.json() if r["id"] == pid][0]
            assert matched["status"] == "COMPLETED"
            assert matched["trip"] is not None
            assert matched["trip"]["status"] == "DELIVERED"
            assert matched["trip"]["completed_at"] is not None

            detail_order = client.get(f"/farmer/orders/{pid}", headers=tok)
            assert detail_order.status_code == 200
            d_json = detail_order.json()
            assert d_json["status"] == "COMPLETED"
            assert d_json["trip_status"] == "DELIVERED"
            assert d_json["settlement"] is not None

            my_pools = client.get("/pools/my", headers=tok)
            assert my_pools.status_code == 200
            p_match = [p for p in my_pools.json() if p["id"] == pool_id][0]
            assert p_match["status"] == "COMPLETED"
            assert p_match["driver_name"] == "Pool Rider Main"

            p_detail = client.get(f"/pools/{pool_id}", headers=tok)
            assert p_detail.status_code == 200
            pd = p_detail.json()
            assert pd["status"] == "COMPLETED"
            assert pd["driver_name"] == "Pool Rider Main"
            assert all(s["status"] == "DELIVERED" for s in pd["stops"])

        # 8. Verify rider route optimization & trip history reflect DELIVERED
        route_after = client.get(
            f"/pools/{pool_id}/route-optimization?rider_lat=12.9617&rider_lng=75.1910",
            headers=h_r,
        )
        assert route_after.status_code == 200, route_after.text
        ra = route_after.json()
        assert ra["pool_status"] == "COMPLETED"
        assert ra["all_picked_up"] is True
        assert ra["all_delivered"] is True
        assert all(s["status"] == "DELIVERED" for s in ra["ordered_stops"])

        hist = client.get("/rider/trips/history", headers=h_r)
        assert hist.status_code == 200
        delivered_count = sum(1 for item in hist.json() if item["status"] == "DELIVERED")
        assert delivered_count == 2
    finally:
        rel_path = photo_url.lstrip("/")
        full_path = Path(rel_path)
        if full_path.exists():
            os.remove(full_path)
