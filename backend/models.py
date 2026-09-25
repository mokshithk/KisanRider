import uuid
from datetime import datetime
from sqlalchemy import Column, String, Integer, Numeric, DateTime, Float, ForeignKey, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from geoalchemy2 import Geometry
from database import Base

class User(Base):
    __tablename__ = "users"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    phone = Column(String(15), unique=True, nullable=False)
    role = Column(String(20), nullable=False)
    full_name = Column(String(100))
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    # A user can be the farmer on many produce requests and/or the rider on many trips.
    produce_requests = relationship(
        "ProduceRequest", back_populates="farmer", foreign_keys="ProduceRequest.farmer_id"
    )
    trips = relationship("Trip", back_populates="rider", foreign_keys="Trip.rider_id")

class ProduceRequest(Base):
    __tablename__ = "produce_requests"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    farmer_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"))
    crop_type = Column(String(50), nullable=False)
    crate_count = Column(Integer, nullable=False)
    weight_kg = Column(Numeric(10, 2))
    pickup_location = Column(Geometry("POINT", srid=4326), nullable=False)
    status = Column(String(20), default="PENDING")
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    farmer = relationship("User", back_populates="produce_requests", foreign_keys=[farmer_id])
    trip = relationship("Trip", back_populates="produce_request", uselist=False)


class Trip(Base):
    """
    A Trip represents a rider accepting (and fulfilling) a ProduceRequest.

    Lifecycle: ACCEPTED -> PICKED_UP -> DELIVERED (or CANCELLED at any point
    before DELIVERED). `completed_at` is set when the trip reaches a terminal
    state (DELIVERED or CANCELLED); it stays NULL while the trip is in
    progress.
    """

    __tablename__ = "trips"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    produce_request_id = Column(
        UUID(as_uuid=True), ForeignKey("produce_requests.id", ondelete="CASCADE"), nullable=False
    )
    rider_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    status = Column(String(20), nullable=False, default="ACCEPTED")
    created_at = Column(DateTime(timezone=True), default=datetime.utcnow)
    completed_at = Column(DateTime(timezone=True), nullable=True)

    produce_request = relationship("ProduceRequest", back_populates="trip", foreign_keys=[produce_request_id])
    rider = relationship("User", back_populates="trips", foreign_keys=[rider_id])
    crate_scans = relationship("CrateScan", back_populates="trip", foreign_keys="CrateScan.trip_id")
    settlement = relationship("Settlement", uselist=False, back_populates="trip")


class CrateScan(Base):
    """
    A single QR-code scan verifying crates at pickup or delivery. A trip
    typically has (at least) one PICKUP scan and one DELIVERY scan, each
    tied to whichever authenticated user performed the scan.
    """

    __tablename__ = "crate_scans"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    trip_id = Column(UUID(as_uuid=True), ForeignKey("trips.id", ondelete="CASCADE"), nullable=False)
    scanned_by_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    scan_type = Column(String(20), nullable=False)
    qr_code = Column(String(255), nullable=False)
    scanned_at = Column(DateTime(timezone=True), default=datetime.utcnow)

    trip = relationship("Trip", back_populates="crate_scans", foreign_keys=[trip_id])
    scanned_by = relationship("User", foreign_keys=[scanned_by_id])


class Settlement(Base):
    """
    The rider payout for one completed (DELIVERED) trip. One-to-one with
    Trip — `trip_id` is unique, so a second settlement attempt on the same
    trip is a DB-level conflict, not just an application-level check.

    total_payout = base_fare + distance_fare + weight_surcharge
    """

    __tablename__ = "settlements"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    trip_id = Column(UUID(as_uuid=True), ForeignKey("trips.id", ondelete="CASCADE"), unique=True, nullable=False)
    base_fare = Column(Float, nullable=False, default=50.0)
    distance_fare = Column(Float, nullable=False)
    weight_surcharge = Column(Float, nullable=False)
    total_payout = Column(Float, nullable=False)
    status = Column(String(20), nullable=False, default="PENDING")
    created_at = Column(DateTime(timezone=True), default=datetime.utcnow)

    trip = relationship("Trip", back_populates="settlement")