"""
Pydantic v2 schemas for the KisanRider farmer-pooling feature.
"""

from datetime import datetime
from typing import List, Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

class PoolCreate(BaseModel):
    """
    Body for ``POST /pools/``.
    
    Note: ``max_qty`` has been removed. The backend defaults it to 1000.0.
    """

    produce_request_id: UUID
    weight_kg: float = Field(..., gt=0)
    crop_type: str = Field(..., min_length=1, max_length=80)
    pickup_window_start: datetime
    pickup_window_end: datetime
    min_qty: float = Field(..., gt=0)
    
    dropoff_district: Optional[str] = Field(None, max_length=80)
    dropoff_mandi_id: Optional[str] = Field(None, max_length=160)
    dropoff_mandi_name: Optional[str] = Field(None, max_length=200)
    dropoff_stall_number: Optional[str] = Field(None, max_length=80)
    
    auto_approve: bool = True
    notes: Optional[str] = Field(None, max_length=2000)

    @model_validator(mode="after")
    def _check_consistency(self) -> "PoolCreate":
        if self.pickup_window_end <= self.pickup_window_start:
            raise ValueError("pickup_window_end must be strictly after pickup_window_start")
        return self


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

class PoolOut(BaseModel):
    """
    Response shape for ``GET /pools/nearby``.
    Includes ``distance_km`` relative to the querying farmer.
    """

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    creator_id: UUID
    creator_full_name: Optional[str] = None
    crop_type: str
    pickup_window_start: datetime
    pickup_window_end: datetime
    min_qty: float
    max_qty: float
    current_qty: float
    status: str
    auto_approve: bool = True
    
    dropoff_district: Optional[str] = None
    dropoff_mandi_id: Optional[str] = None
    dropoff_mandi_name: Optional[str] = None
    dropoff_stall_number: Optional[str] = None
    
    notes: Optional[str] = None
    member_count: int = 0
    created_at: datetime
    locked_at: Optional[datetime] = None
    
    # Phase 6: Distance from the querying farmer's location
    distance_km: Optional[float] = None
    
    # Phase 7: Creator's pickup address
    pickup_address: Optional[str] = None


# ---------------------------------------------------------------------------
# Membership
# ---------------------------------------------------------------------------

class PoolMemberCreate(BaseModel):
    """
    Body for ``POST /pools/{id}/join``.
    """
    produce_request_id: UUID
    weight_kg: float = Field(..., gt=0, description="Weight in kilograms.")


class PoolMemberOut(BaseModel):
    """
    One member as exposed to a farmer viewing the pool detail.
    """

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    farmer_id: UUID
    produce_request_id: UUID
    weight_kg: float
    status: str
    requested_at: datetime
    decided_at: Optional[datetime] = None
    cancellation_reason: Optional[str] = None
    
    # Phase 7: Name of the farmer
    farmer_full_name: Optional[str] = None


# ---------------------------------------------------------------------------
# Stops (route order)
# ---------------------------------------------------------------------------

class PoolStopOut(BaseModel):
    """A single pickup stop in the pool's future route."""

    model_config = ConfigDict(from_attributes=True)

    sequence: int
    produce_request_id: UUID
    status: str


# ---------------------------------------------------------------------------
# Detail (PoolOut + members + stops)
# ---------------------------------------------------------------------------

class PoolDetailOut(PoolOut):
    """
    Response for ``GET /pools/{id}`` and the mutating pool endpoints.
    """

    members: List[PoolMemberOut] = Field(default_factory=list)
    stops: List[PoolStopOut] = Field(default_factory=list)


# ---------------------------------------------------------------------------
# Phase 3 — rider accept result
# ---------------------------------------------------------------------------

class PoolAcceptResult(BaseModel):
    """
    Response for ``POST /pools/{id}/accept``.
    """
    pool_id: UUID
    pool_status: str
    trip_ids: List[UUID] = Field(default_factory=list)
    trips_created: int = 0


# ---------------------------------------------------------------------------
# Phase 6 — auto-matching
# ---------------------------------------------------------------------------

class NearbyFarmerOut(BaseModel):
    """
    One unpooled PENDING ProduceRequest near the current farmer.
    """
    produce_request_id: UUID
    farmer_id: UUID
    farmer_name: str
    crop_type: str
    weight_kg: float
    distance_km: float
    dropoff_mandi_name: Optional[str] = None
    dropoff_district: Optional[str] = None


class PoolGroupCreate(BaseModel):
    """
    Body for ``POST /pools/group``.
    """
    creator_produce_request_id: UUID
    other_produce_request_ids: List[UUID]
    pickup_window_start: datetime
    pickup_window_end: datetime