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

    email = Column(String(255), unique=True, index=True, nullable=False)
    phone = Column(String(15), unique=True, nullable=True)
    phone_number = Column(String(15), nullable=True, index=True)

    role = Column(String(20), nullable=False, default="FARMER")
    full_name = Column(String(100), nullable=False)
    password_hash = Column(String(255), nullable=True)

    district = Column(String(80), nullable=True)
    taluk_village = Column(String(120), nullable=True)
    state = Column(String(80), nullable=True, default="Karnataka")

    farm_size_acres = Column(Float, nullable=True)
    primary_crops = Column(String(255), nullable=True)
    farm_address = Column(Text, nullable=True)
    landmark = Column(String(255), nullable=True)

    is_on_duty = Column(
        Boolean,
        nullable=False,
        default=False,
        server_default="false",
    )

    license_number = Column(String(30), nullable=True)
    vehicle_type = Column(String(80), nullable=True)
    vehicle_number = Column(String(20), nullable=True)
    payload_capacity_kg = Column(Float, nullable=True)
    operating_routes = Column(String(255), nullable=True)

    bank_name = Column(String(100), nullable=True)
    account_number = Column(String(30), nullable=True)
    ifsc_code = Column(String(20), nullable=True)
    upi_id = Column(String(100), nullable=True)

    preferred_language = Column(
        String(10),
        nullable=False,
        default="en",
        server_default="en",
    )

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
    saved_addresses = relationship(
        "SavedAddress",
        back_populates="farmer",
        foreign_keys="SavedAddress.farmer_id",
        cascade="all, delete-orphan",
    )


class SavedAddress(Base):
    __tablename__ = "saved_addresses"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    farmer_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    title = Column(String(80), nullable=False)
    address_text = Column(String(500), nullable=False)
    landmark = Column(String(255), nullable=True)
    latitude = Column(Float, nullable=True)
    longitude = Column(Float, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    farmer = relationship(
        "User",
        back_populates="saved_addresses",
        foreign_keys=[farmer_id],
    )


class ProduceRequest(Base):
    """
    A farmer's produce transport request.

    ## Quantity metric

    `weight_kg` is the SINGLE quantity field.

    ## Status lifecycle

    PENDING -> ACCEPTED -> PICKED_UP -> COMPLETED
    Or:
    PENDING -> CANCELLED  (farmer cancels before acceptance)

    `cancellation_reason` is populated only when the farmer cancels a
    PENDING order from the Order Detail screen.
    """

    __tablename__ = "produce_requests"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    farmer_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"))
    crop_type = Column(String(50), nullable=False)
    weight_kg = Column(Numeric(10, 2))

    pickup_location = Column(Geometry("POINT", srid=4326), nullable=False)
    pickup_address = Column(String(500), nullable=True)
    pickup_landmark = Column(String(255), nullable=True)

    dropoff_district = Column(String(80), nullable=True)
    dropoff_mandi_id = Column(String(160), nullable=True)
    dropoff_mandi_name = Column(String(200), nullable=True)
    dropoff_stall_number = Column(String(80), nullable=True)

    dropoff_location = Column(String(255), nullable=True)
    dropoff_lat = Column(Float, nullable=True)
    dropoff_lng = Column(Float, nullable=True)
    pickup_otp = Column(String(4), nullable=True)
    status = Column(String(20), default="PENDING")

    # Populated when the farmer cancels a PENDING order. NULL otherwise.
    cancellation_reason = Column(String(500), nullable=True)

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

    pickup_address = Column(String(500), nullable=True)
    pickup_landmark = Column(String(255), nullable=True)
    pickup_latitude = Column(Float, nullable=True)
    pickup_longitude = Column(Float, nullable=True)

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

    base_fare = Column(Float, nullable=False, default=50.0)
    distance_fare = Column(Float, nullable=False)
    weight_surcharge = Column(Float, nullable=False)
    total_payout = Column(Float, nullable=False)

    crop_name = Column(String(50), nullable=True)
    quantity_kg = Column(Float, nullable=True)
    gross_amount = Column(Float, nullable=True)
    rider_fare = Column(Float, nullable=True)
    platform_fee = Column(Float, nullable=True)
    net_payout = Column(Float, nullable=True)

    status = Column(String(20), nullable=False, default="PENDING")
    created_at = Column(DateTime(timezone=True), default=datetime.utcnow)

    trip = relationship("Trip", back_populates="settlement")