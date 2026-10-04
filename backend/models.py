import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from geoalchemy2 import Geometry

from database import Base


class User(Base):
    __tablename__ = "users"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)

    # Email is the primary signup identifier for the OTP flow.
    email = Column(String(255), unique=True, index=True, nullable=False)

    # Legacy phone-only accounts; kept for /users/ back-compat. Nullable
    # because new email-signup users never supply a phone.
    phone = Column(String(15), unique=True, nullable=True)

    role = Column(String(20), nullable=False, default="FARMER")
    full_name = Column(String(100), nullable=False)

    # Bcrypt hash. Nullable so users created via the legacy /users/ path
    # or Supabase Auth (who have no local password) can still exist.
    # Every user created by /auth/verify-otp has this populated.
    password_hash = Column(String(255), nullable=True)

    # ----- Basic info ------------------------------------------------------
    # `district` and `state` are captured at signup; `taluk_village` is
    # filled in later from the Account screen.
    district = Column(String(80), nullable=True)
    taluk_village = Column(String(120), nullable=True)
    state = Column(String(80), nullable=True, default="Karnataka")

    # ----- Farm info -------------------------------------------------------
    farm_size_acres = Column(Float, nullable=True)
    primary_crops = Column(String(255), nullable=True)

    # ----- Pickup address --------------------------------------------------
    # `farm_address` is free-text; `landmark` is a short reference line the
    # rider can look for on arrival. Both nullable — a user may sign up and
    # never fill these in.
    farm_address = Column(Text, nullable=True)
    landmark = Column(String(255), nullable=True)

    # ----- Payout info -----------------------------------------------------
    # Stored as plain strings. If you later decide these need encryption at
    # rest, do it at the service layer — the ORM column type stays String.
    bank_name = Column(String(100), nullable=True)
    account_number = Column(String(30), nullable=True)
    ifsc_code = Column(String(20), nullable=True)
    upi_id = Column(String(100), nullable=True)

    # ----- Preferences -----------------------------------------------------
    # ISO 639-1 language code. `server_default` matters: it backfills 'en'
    # for any row inserted before this column existed and for direct SQL
    # inserts that omit it.
    preferred_language = Column(
        String(10),
        nullable=False,
        default="en",
        server_default="en",
    )

    # Email-OTP signup sets this True once the code is verified.
    # Defaults True so legacy rows are treated as already verified.
    is_verified = Column(Boolean, nullable=False, default=True)

    created_at = Column(DateTime(timezone=True), server_default=func.now())

    produce_requests = relationship(
        "ProduceRequest",
        back_populates="farmer",
        foreign_keys="ProduceRequest.farmer_id",
    )
    trips = relationship(
        "Trip",
        back_populates="rider",
        foreign_keys="Trip.rider_id",
    )


class ProduceRequest(Base):
    __tablename__ = "produce_requests"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    farmer_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"))
    crop_type = Column(String(50), nullable=False)
    crate_count = Column(Integer, nullable=False)
    weight_kg = Column(Numeric(10, 2))
    pickup_location = Column(Geometry("POINT", srid=4326), nullable=False)
    dropoff_location = Column(String(255), nullable=True)
    dropoff_lat = Column(Float, nullable=True)
    dropoff_lng = Column(Float, nullable=True)
    pickup_otp = Column(String(4), nullable=True)
    status = Column(String(20), default="PENDING")
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    farmer = relationship(
        "User",
        back_populates="produce_requests",
        foreign_keys=[farmer_id],
    )
    trip = relationship(
        "Trip",
        back_populates="produce_request",
        uselist=False,
    )


class Trip(Base):
    """
    A Trip represents a rider accepting (and fulfilling) a ProduceRequest.

    Lifecycle: ACCEPTED -> PICKED_UP -> DELIVERED (or CANCELLED at any
    point before DELIVERED). `completed_at` is set when the trip reaches a
    terminal state (DELIVERED or CANCELLED); it stays NULL while the trip
    is in progress.
    """

    __tablename__ = "trips"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    produce_request_id = Column(
        UUID(as_uuid=True),
        ForeignKey("produce_requests.id", ondelete="CASCADE"),
        nullable=False,
    )
    rider_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    status = Column(String(20), nullable=False, default="ACCEPTED")
    created_at = Column(DateTime(timezone=True), default=datetime.utcnow)
    completed_at = Column(DateTime(timezone=True), nullable=True)

    produce_request = relationship(
        "ProduceRequest",
        back_populates="trip",
        foreign_keys=[produce_request_id],
    )
    rider = relationship("User", back_populates="trips", foreign_keys=[rider_id])
    crate_scans = relationship(
        "CrateScan",
        back_populates="trip",
        foreign_keys="CrateScan.trip_id",
    )
    settlement = relationship("Settlement", uselist=False, back_populates="trip")


class CrateScan(Base):
    """
    A single QR-code scan verifying crates at pickup or delivery. A trip
    typically has (at least) one PICKUP scan and one DELIVERY scan, each
    tied to whichever authenticated user performed the scan.
    """

    __tablename__ = "crate_scans"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    trip_id = Column(
        UUID(as_uuid=True),
        ForeignKey("trips.id", ondelete="CASCADE"),
        nullable=False,
    )
    scanned_by_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    scan_type = Column(String(20), nullable=False)
    qr_code = Column(String(255), nullable=False)
    scanned_at = Column(DateTime(timezone=True), default=datetime.utcnow)

    trip = relationship("Trip", back_populates="crate_scans", foreign_keys=[trip_id])
    scanned_by = relationship("User", foreign_keys=[scanned_by_id])


class Settlement(Base):
    """
    The financial record for one completed (DELIVERED) trip, one-to-one
    with Trip.
    """

    __tablename__ = "settlements"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    trip_id = Column(
        UUID(as_uuid=True),
        ForeignKey("trips.id", ondelete="CASCADE"),
        unique=True,
        nullable=False,
    )

    rider_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    farmer_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )

    # ----- Rider fare breakdown --------------------------------------------
    base_fare = Column(Float, nullable=False, default=50.0)
    distance_fare = Column(Float, nullable=False)
    weight_surcharge = Column(Float, nullable=False)
    total_payout = Column(Float, nullable=False)

    # ----- Farmer payout breakdown -----------------------------------------
    crop_name = Column(String(50), nullable=True)
    quantity_kg = Column(Float, nullable=True)
    gross_amount = Column(Float, nullable=True)
    rider_fare = Column(Float, nullable=True)
    platform_fee = Column(Float, nullable=True)
    net_payout = Column(Float, nullable=True)

    # ----- Metadata --------------------------------------------------------
    status = Column(String(20), nullable=False, default="PENDING")
    created_at = Column(DateTime(timezone=True), default=datetime.utcnow)

    trip = relationship("Trip", back_populates="settlement")