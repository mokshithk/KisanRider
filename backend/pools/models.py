import uuid
from enum import Enum

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship

from database import Base


class PoolStatus(str, Enum):
    OPEN = "OPEN"
    DRIVER_ASSIGNED = "DRIVER_ASSIGNED"
    LOCKED = "LOCKED"
    IN_PROGRESS = "IN_PROGRESS"
    COMPLETED = "COMPLETED"
    CANCELLED = "CANCELLED"


class PoolMemberStatus(str, Enum):
    PENDING = "PENDING"
    APPROVED = "APPROVED"
    REJECTED = "REJECTED"
    CANCELLED = "CANCELLED"
    PICKED_UP = "PICKED_UP"
    COMPLETED = "COMPLETED"
    REQUESTED = "REQUESTED"
    ACCEPTED = "ACCEPTED"
    WITHDRAWN = "WITHDRAWN"


class Pool(Base):
    __tablename__ = "pools"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    creator_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    crop_type = Column(String(80), nullable=False)

    dropoff_district = Column(String(80), nullable=True)
    dropoff_mandi_id = Column(String(160), nullable=True)
    dropoff_mandi_name = Column(String(200), nullable=True)
    dropoff_stall_number = Column(String(80), nullable=True)

    pickup_window_start = Column(DateTime(timezone=True), nullable=False)
    pickup_window_end = Column(DateTime(timezone=True), nullable=False)

    min_qty = Column(Float, nullable=False)
    max_qty = Column(Float, nullable=False)
    current_qty = Column(
        Float,
        nullable=False,
        default=0.0,
        server_default="0",
    )

    status = Column(
        String(20),
        nullable=False,
        default=PoolStatus.OPEN.value,
        server_default=PoolStatus.OPEN.value,
    )
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    locked_at = Column(DateTime(timezone=True), nullable=True)
    notes = Column(Text, nullable=True)

    auto_approve = Column(
        Boolean,
        nullable=False,
        default=True,
        server_default="true",
    )

    members = relationship(
        "PoolMember",
        back_populates="pool",
        cascade="all, delete-orphan",
    )
    stops = relationship(
        "PoolStop",
        back_populates="pool",
        cascade="all, delete-orphan",
    )
    
    # PHASE 3
    trips = relationship(
        "Trip",
        back_populates="pool",
    )


class PoolMember(Base):
    __tablename__ = "pool_members"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    pool_id = Column(
        UUID(as_uuid=True),
        ForeignKey("pools.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    farmer_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    produce_request_id = Column(
        UUID(as_uuid=True),
        ForeignKey("produce_requests.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )

    weight_kg = Column(Float, nullable=False)

    status = Column(
        String(20),
        nullable=False,
        default=PoolMemberStatus.REQUESTED.value,
        server_default=PoolMemberStatus.REQUESTED.value,
    )

    requested_at = Column(DateTime(timezone=True), server_default=func.now())
    decided_at = Column(DateTime(timezone=True), nullable=True)
    contribution_to_total = Column(Float, nullable=True)
    route_position = Column(Integer, nullable=True)
    cancellation_reason = Column(String(500), nullable=True)

    pool = relationship("Pool", back_populates="members")


class PoolStop(Base):
    __tablename__ = "pool_stops"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    pool_id = Column(
        UUID(as_uuid=True),
        ForeignKey("pools.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    produce_request_id = Column(
        UUID(as_uuid=True),
        ForeignKey("produce_requests.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    sequence = Column(Integer, nullable=False)

    status = Column(
        String(20),
        nullable=False,
        default="PENDING",
        server_default="PENDING",
    )

    arrived_at = Column(DateTime(timezone=True), nullable=True)
    picked_up_at = Column(DateTime(timezone=True), nullable=True)

    pool = relationship("Pool", back_populates="stops")