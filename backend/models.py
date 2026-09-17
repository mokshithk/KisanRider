import uuid
from datetime import datetime
from sqlalchemy import Column, String, Integer, Numeric, DateTime, ForeignKey, func
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