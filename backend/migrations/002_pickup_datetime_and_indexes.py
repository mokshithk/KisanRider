"""
Additive migration 002:
- Adds requested_pickup_at column to produce_requests table
- Creates performance and filtering indexes for nearby requests, status filtering, and trip lookup
Non-destructive: Uses ADD COLUMN IF NOT EXISTS and CREATE INDEX IF NOT EXISTS.
"""

import sys
from pathlib import Path
from sqlalchemy import text

# Ensure backend root is on sys.path
backend_dir = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(backend_dir))

from database import engine

MIGRATION_SQL = """
-- 1. Add requested_pickup_at column to produce_requests
ALTER TABLE produce_requests 
ADD COLUMN IF NOT EXISTS requested_pickup_at TIMESTAMPTZ NULL;

-- 2. Create index on status and requested_pickup_at for fast nearby and expiry queries
CREATE INDEX IF NOT EXISTS ix_produce_requests_status_pickup 
ON produce_requests(status, requested_pickup_at);

-- 3. Create index on dropoff_district
CREATE INDEX IF NOT EXISTS ix_produce_requests_dropoff_district 
ON produce_requests(dropoff_district);

-- 4. Create index on trips rider_id and status
CREATE INDEX IF NOT EXISTS ix_trips_rider_status 
ON trips(rider_id, status);

-- 5. Create index on trips pool_id
CREATE INDEX IF NOT EXISTS ix_trips_pool_id 
ON trips(pool_id);
"""

def run_migration():
    print("Running additive migration 002_pickup_datetime_and_indexes...")
    with engine.connect() as conn:
        for statement in MIGRATION_SQL.strip().split(";"):
            clean_stmt = statement.strip()
            if clean_stmt:
                conn.execute(text(clean_stmt))
        conn.commit()
    print("Migration 002_pickup_datetime_and_indexes executed successfully.")

if __name__ == "__main__":
    run_migration()
