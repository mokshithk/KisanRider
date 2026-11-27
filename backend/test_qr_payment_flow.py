"""
End-to-end tests for QR Mandi Payment, delivery-time mandi rates, ₹50/kg fallback,
single-QR pool payment with per-farmer auto-split, numeric PIN validation, and
live reflection across Rider, Farmer, and Admin views.
"""

import os
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from database import SessionLocal
from main import app
import models
import payment_service
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
        email=f"qr_farmer_{suffix}_{uuid.uuid4().hex[:6]}@example.com",
        role="FARMER",
        full_name=name,
        phone_number="9845001122",
        district="Kolar",
        farm_size_acres=4.0,
        primary_crops="Tomato, ExoticFruit",
        farm_address="Kolar Farm Gate",
    )
    db.add(u)
    db.commit()
    db.refresh(u)
    return u


def _create_rider(db, suffix: str, name: str):
    u = models.User(
        email=f"qr_rider_{suffix}_{uuid.uuid4().hex[:6]}@example.com",
        role="RIDER",
        full_name=name,
        phone_number="9845009988",
        vehicle_type="Mini Truck",
        vehicle_number="KA-07-AA-4455",
        payload_capacity_kg=2500.0,
        license_number="KA07-20240004455",
        district="Kolar",
        operating_routes="Kolar - Bengaluru",
        is_on_duty=True,
    )
    db.add(u)
    db.commit()
    db.refresh(u)
    return u


def _create_admin(db, suffix: str):
    u = models.User(
        email=f"qr_admin_{suffix}_{uuid.uuid4().hex[:6]}@example.com",
        role="ADMIN",
        full_name="QR Test Admin",
        is_active=True,
    )
    db.add(u)
    db.commit()
    db.refresh(u)
    return u


def test_delivery_crop_rate_resolution_mandi_api_and_50_fallback(monkeypatch):
    """
    Verify Q1 & Q6:
    - Listed crop uses live Data.gov.in mandi rate converted from Rs/Qtl to Rs/kg.
    - Unlisted crop falls back cleanly to Rs 50.0 / kg.
    - Missing API key falls back cleanly to Rs 50.0 / kg.
    """
    payment_service.clear_rate_cache()

    # Seed deterministic live Data.gov.in cache entries
    now = time.time()
    monkeypatch.setenv("DATA_GOV_API_KEY", "test-demo-key")
    payment_service._LIVE_RATE_CACHE["kolar"] = (
        now,
        [
            {
                "crop": "Tomato",
                "rate_per_kg": 24.0,
                "mandi": "Kolar APMC",
                "district": "Kolar",
            },
            {
                "crop": "Arecanut(Betelnut/Supari)",
                "rate_per_kg": 410.0,
                "mandi": "Bantwala APMC",
                "district": "Dakshina Kannada",
            },
        ],
    )
    payment_service._LIVE_RATE_CACHE["__all__"] = payment_service._LIVE_RATE_CACHE["kolar"]

    # 1. Exact/plural match ("Tomatoes" matches "Tomato" @ 24/kg)
    rate_tomato, src_tomato, mandi_tomato = payment_service.resolve_delivery_crop_rate_per_kg(
        "Tomatoes", district="Kolar", mandi_name="Kolar APMC"
    )
    assert rate_tomato == 24.0
    assert src_tomato == "mandi_api"
    assert mandi_tomato == "Kolar APMC"

    # 2. Unlisted crop -> fallback Rs 50/kg
    rate_unlisted, src_unlisted, _ = payment_service.resolve_delivery_crop_rate_per_kg(
        "Dragonfruit", district="Kolar", mandi_name="Kolar APMC"
    )
    assert rate_unlisted == 50.0
    assert src_unlisted == "fallback"

    # 3. API key absent -> fallback Rs 50/kg
    monkeypatch.delenv("DATA_GOV_API_KEY", raising=False)
    rate_no_key, src_no_key, _ = payment_service.resolve_delivery_crop_rate_per_kg(
        "Tomato", district="Kolar", mandi_name="Kolar APMC"
    )
    assert rate_no_key == 50.0
    assert src_no_key == "fallback"
    payment_service.clear_rate_cache()


def test_individual_qr_payment_end_to_end(client, db, monkeypatch):
    """
    Full individual delivery + QR generate + Scanner inspect + PIN validation +
    auto-split payment + polling + Rider/Farmer/Admin sync.
    """
    payment_service.clear_rate_cache()
    monkeypatch.setenv("DATA_GOV_API_KEY", "test-demo-key")
    now_ts = time.time()
    payment_service._LIVE_RATE_CACHE["kolar"] = (
        now_ts,
        [
            {
                "crop": "Tomato",
                "rate_per_kg": 30.0,  # Rs 30/kg from Mandi API
                "mandi": "Kolar APMC",
                "district": "Kolar",
            }
        ],
    )
    payment_service._LIVE_RATE_CACHE["__all__"] = payment_service._LIVE_RATE_CACHE["kolar"]

    farmer = _create_farmer(db, "ind", "QR Individual Farmer")
    rider = _create_rider(db, "ind", "QR Individual Rider")
    admin = _create_admin(db, "ind")

    f_tok = client.post(f"/auth/dev-token?user_id={farmer.id}").json()["access_token"]
    r_tok = client.post(f"/auth/dev-token?user_id={rider.id}").json()["access_token"]
    a_tok = client.post(f"/auth/dev-token?user_id={admin.id}").json()["access_token"]
    h_f = {"Authorization": f"Bearer {f_tok}"}
    h_r = {"Authorization": f"Bearer {r_tok}"}
    h_a = {"Authorization": f"Bearer {a_tok}"}

    now = datetime.now(timezone.utc)
    pr = client.post(
        "/produce-requests/",
        json={
            "crop_type": "Tomatoes",
            "weight_kg": 200.0,
            "latitude": 13.1362,
            "longitude": 78.1291,
            "pickup_address": "Kolar East Farm",
            "dropoff_district": "Kolar",
            "dropoff_mandi_name": "Kolar APMC",
            "requested_pickup_at": (now + timedelta(minutes=30)).isoformat(),
            "pickup_window_start": (now - timedelta(minutes=1)).isoformat(),
            "pickup_window_end": (now + timedelta(hours=5)).isoformat(),
        },
        headers=h_f,
    )
    assert pr.status_code == 201, pr.text
    pr_id = pr.json()["id"]

    # Retrieve OTP
    me_orders = client.get("/produce-requests/farmer/me", headers=h_f).json()
    otp = next(o["pickup_otp"] for o in me_orders if o["id"] == pr_id)

    # Rider accepts
    acc = client.post(
        f"/trips/accept?request_id={pr_id}",
        json={"rider_expected_pickup_at": (now + timedelta(minutes=15)).isoformat()},
        headers=h_r,
    )
    assert acc.status_code in (200, 201), acc.text
    trip_id = acc.json()["trip_id"]

    # Verify pickup OTP
    v = client.post(f"/rider/trips/{trip_id}/verify-otp", json={"otp": otp}, headers=h_r)
    assert v.status_code == 200, v.text

    # Mark delivered (creates Settlement using delivery-time rate Rs 30/kg -> gross 6000)
    deliv = client.patch(
        f"/trips/{trip_id}/status",
        json={"status": "DELIVERED", "distance_km": 10.0},
        headers=h_r,
    )
    assert deliv.status_code == 200, deliv.text

    # Rider active list carries settlement metadata & PENDING status
    active_list = client.get("/rider/trips/active", headers=h_r).json()
    t_row = next(x for x in active_list if x["order_id"] == trip_id)
    assert t_row["status"] == "COMPLETED"
    assert t_row["payment_status"] == "PENDING"
    assert t_row["rate_per_kg"] == 30.0
    assert t_row["rate_source"] == "mandi_api"
    assert t_row["gross_amount"] == 6000.0
    settlement_id = t_row["settlement_id"]
    assert settlement_id is not None

    # Rider generates QR via /trips/{trip_id}/generate-qr
    qr_resp = client.post(f"/trips/{trip_id}/generate-qr", headers=h_r)
    assert qr_resp.status_code == 200, qr_resp.text
    qr_json = qr_resp.json()
    assert qr_json["kind"] == "INDIVIDUAL"
    assert qr_json["target_id"] == settlement_id
    assert qr_json["status"] == "PENDING"
    assert qr_json["total_amount"] == 6000.0
    assert qr_json["qr_data"].startswith(f"KISANRIDER|{settlement_id}|6000")
    assert round(
        qr_json["rider_fare"] + qr_json["platform_fee"] + qr_json["farmers_net_payout"], 2
    ) == 6000.0

    # Polling returns PENDING before pay
    poll_before = client.get(f"/settlements/{settlement_id}/status", headers=h_r)
    assert poll_before.status_code == 200
    assert poll_before.json()["status"] == "PENDING"

    # Demo Scanner App inspects QR (no auth needed for external mandi scanner)
    insp = client.get("/payments/qr/inspect", params={"qr_data": qr_json["qr_data"]})
    assert insp.status_code == 200, insp.text
    assert insp.json()["total_amount"] == 6000.0
    assert insp.json()["crop_name"] == "Tomatoes"

    # Numeric PIN check: reject letters / short PIN
    bad_alpha = client.post(
        "/payments/qr/pay",
        json={"qr_data": qr_json["qr_data"], "pin": "abcd"},
    )
    assert bad_alpha.status_code == 400
    bad_short = client.post(
        "/payments/qr/pay",
        json={"qr_data": qr_json["qr_data"], "pin": "12"},
    )
    assert bad_short.status_code in (400, 422)

    # Demo Scanner pays with valid numeric PIN
    pay_resp = client.post(
        "/payments/qr/pay",
        json={"qr_data": qr_json["qr_data"], "pin": "4829"},
    )
    assert pay_resp.status_code == 200, pay_resp.text
    pay_json = pay_resp.json()
    assert pay_json["success"] is True
    assert pay_json["status"] == "PAID"
    assert pay_json["payment_reference"].startswith("QR-")

    # Double pay blocked cleanly
    dup_pay = client.post(
        "/payments/qr/pay",
        json={"qr_data": qr_json["qr_data"], "pin": "4829"},
    )
    assert dup_pay.status_code == 400

    # Polling reflects PAID immediately
    poll_after = client.get(f"/trips/{trip_id}/payment-status", headers=h_r)
    assert poll_after.status_code == 200
    assert poll_after.json()["status"] == "PAID"
    assert poll_after.json()["payment_reference"] == pay_json["payment_reference"]

    # Rider earnings, trip history detail, Farmer order detail, Farmer settlements, Admin settlements all updated
    rider_settle = client.get("/settlements/me", headers=h_r).json()
    assert any(s["id"] == settlement_id and s["status"] == "PAID" for s in rider_settle)

    rider_detail = client.get(f"/rider/trips/{trip_id}", headers=h_r).json()
    assert rider_detail["fare"]["payment_method"] == "QR Payment at Mandi"
    assert rider_detail["fare"]["settlement_status"] == "PAID"
    assert rider_detail["fare"]["crop_gross_amount"] == 6000.0

    farmer_order = client.get(f"/farmer/orders/{pr_id}", headers=h_f).json()
    assert farmer_order["settlement"]["status"] == "PAID"
    assert farmer_order["settlement"]["gross_amount"] == 6000.0
    assert farmer_order["settlement"]["payment_reference"] == pay_json["payment_reference"]

    admin_detail = client.get(f"/admin/settlements/{settlement_id}", headers=h_a).json()
    assert admin_detail["settlement"]["status"] == "PAID"
    assert admin_detail["settlement"]["payment_reference"] == pay_json["payment_reference"]
    payment_service.clear_rate_cache()


def test_pool_single_qr_payment_with_50_fallback_and_split(client, db, monkeypatch):
    """
    Verify Q5 (Option A: one single QR for whole pool total -> system auto-splits per farmer)
    and Rs 50/kg fallback when crop is not in mandi rates.
    """
    payment_service.clear_rate_cache()
    monkeypatch.setenv("DATA_GOV_API_KEY", "test-demo-key")
    # Live list does NOT contain 'SpecialMalt' -> triggers Rs 50/kg fallback!
    payment_service._LIVE_RATE_CACHE["kolar"] = (
        time.time(),
        [{"crop": "Tomato", "rate_per_kg": 22.0, "mandi": "Kolar APMC", "district": "Kolar"}],
    )
    payment_service._LIVE_RATE_CACHE["__all__"] = payment_service._LIVE_RATE_CACHE["kolar"]

    farmer_a = _create_farmer(db, "p_a", "Pool QR Farmer A")
    farmer_b = _create_farmer(db, "p_b", "Pool QR Farmer B")
    rider = _create_rider(db, "p_r", "Pool QR Rider")

    tok_a = client.post(f"/auth/dev-token?user_id={farmer_a.id}").json()["access_token"]
    tok_b = client.post(f"/auth/dev-token?user_id={farmer_b.id}").json()["access_token"]
    tok_r = client.post(f"/auth/dev-token?user_id={rider.id}").json()["access_token"]
    h_a = {"Authorization": f"Bearer {tok_a}"}
    h_b = {"Authorization": f"Bearer {tok_b}"}
    h_r = {"Authorization": f"Bearer {tok_r}"}

    now = datetime.now(timezone.utc)
    w_start = now - timedelta(minutes=1)
    w_end = now + timedelta(hours=6)

    pr_a = client.post(
        "/produce-requests/",
        json={
            "crop_type": "SpecialMalt",
            "weight_kg": 120.0,
            "latitude": 13.1362,
            "longitude": 78.1291,
            "pickup_address": "Farm A",
            "dropoff_district": "Kolar",
            "dropoff_mandi_name": "Kolar APMC",
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
            "crop_type": "SpecialMalt",
            "weight_kg": 120.0,
            "min_qty": 50.0,
            "dropoff_district": "Kolar",
            "dropoff_mandi_name": "Kolar APMC",
            "pickup_window_start": w_start.isoformat(),
            "pickup_window_end": w_end.isoformat(),
        },
        headers=h_a,
    ).json()
    pool_id = pool["id"]

    pr_b = client.post(
        "/produce-requests/",
        json={
            "crop_type": "SpecialMalt",
            "weight_kg": 80.0,
            "latitude": 13.1400,
            "longitude": 78.1320,
            "pickup_address": "Farm B",
            "dropoff_district": "Kolar",
            "dropoff_mandi_name": "Kolar APMC",
            "for_pool": True,
        },
        headers=h_b,
    ).json()

    join_r = client.post(
        f"/pools/{pool_id}/join",
        json={"produce_request_id": pr_b["id"], "weight_kg": 80.0},
        headers=h_b,
    )
    assert join_r.status_code == 200, join_r.text

    acc = client.post(
        f"/pools/{pool_id}/accept",
        json={"rider_expected_pickup_at": (now + timedelta(minutes=15)).isoformat()},
        headers=h_r,
    )
    assert acc.status_code in (200, 201), acc.text

    otp_a = next(
        m["pickup_otp"]
        for m in client.get(f"/pools/{pool_id}", headers=h_a).json()["members"]
        if m["farmer_id"] == str(farmer_a.id)
    )
    otp_b = next(
        m["pickup_otp"]
        for m in client.get(f"/pools/{pool_id}", headers=h_b).json()["members"]
        if m["farmer_id"] == str(farmer_b.id)
    )

    assert client.post(
        f"/pools/{pool_id}/verify-farmer-otp",
        json={"produce_request_id": pr_a["id"], "otp": otp_a},
        headers=h_r,
    ).status_code == 200
    assert client.post(
        f"/pools/{pool_id}/verify-farmer-otp",
        json={"produce_request_id": pr_b["id"], "otp": otp_b},
        headers=h_r,
    ).status_code == 200

    tiny_png = (
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
        b"\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc```\x00\x00"
        b"\x00\x04\x00\x01\xf6\x178U\x00\x00\x00\x00IEND\xaeB`\x82"
    )
    up = client.post(
        "/uploads/delivery-photo",
        files={"file": ("proof.png", tiny_png, "image/png")},
        headers=h_r,
    ).json()
    photo_url = up["image_url"]

    try:
        deliv = client.post(
            f"/pools/{pool_id}/deliver",
            json={"delivery_photo_url": photo_url, "distance_km": 10.0},
            headers=h_r,
        )
        assert deliv.status_code == 200, deliv.text

        # Generate SINGLE QR for the whole pool (200kg @ fallback Rs 50/kg = Rs 10,000 total)
        qr = client.post(f"/pools/{pool_id}/generate-qr", headers=h_r)
        assert qr.status_code == 200, qr.text
        q = qr.json()
        assert q["kind"] == "POOL"
        assert q["total_amount"] == 10000.0
        assert q["rate_per_kg"] == 50.0
        assert q["rate_source"] == "fallback"
        assert len(q["items"]) == 2
        assert q["qr_data"].startswith(f"KISANRIDER|{pool_id}|10000")
        assert round(
            q["rider_fare"] + q["platform_fee"] + q["farmers_net_payout"], 2
        ) == 10000.0

        # Pay once via Demo Scanner QR pay
        insp = client.get("/payments/qr/inspect", params={"qr_data": q["qr_data"]})
        assert insp.status_code == 200
        assert insp.json()["total_amount"] == 10000.0

        pay = client.post(
            "/payments/qr/pay",
            json={"qr_data": q["qr_data"], "pin": "1234"},
        )
        assert pay.status_code == 200, pay.text
        p = pay.json()
        assert p["success"] is True
        assert p["status"] == "PAID"
        assert all(it["status"] == "PAID" for it in p["items"])

        # Both Farmers see PAID in Pool Detail (my_settlement)
        det_a = client.get(f"/pools/{pool_id}", headers=h_a).json()
        det_b = client.get(f"/pools/{pool_id}", headers=h_b).json()
        assert det_a["pool_payment_status"] == "PAID"
        assert det_a["my_settlement"]["status"] == "PAID"
        assert det_a["my_settlement"]["gross_amount"] == 6000.0
        assert det_b["my_settlement"]["status"] == "PAID"
        assert det_b["my_settlement"]["gross_amount"] == 4000.0

        # Rider route-optimization & active list reflect PAID
        ro = client.get(
            f"/pools/{pool_id}/route-optimization?rider_lat=13.13&rider_lng=78.12",
            headers=h_r,
        ).json()
        assert ro["payment_status"] == "PAID"
        assert ro["total_crop_value"] == 10000.0
    finally:
        rel_path = photo_url.lstrip("/")
        if Path(rel_path).exists():
            os.remove(rel_path)
        payment_service.clear_rate_cache()
