"""
Additive migration 003:
- Adds pickup_window_start and pickup_window_end columns to produce_requests table
- Backfills pickup_window_start and pickup_window_end from requested_pickup_at for existing rows
- Adds rider_expected_pickup_at column to trips table
- Creates performance and filtering indexes
Non-destructive: Uses ADD COLUMN IF NOT EXISTS and CREATE INDEX IF NOT EXISTS.
"""

import sys
from pathlib import Path
from sqlalchemy import text

backend_dir = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(backend_dir))

from database import engine

MIGRATION_SQL = """
-- 1. Add pickup window columns to produce_requests
ALTER TABLE produce_requests 
ADD COLUMN IF NOT EXISTS pickup_window_start TIMESTAMPTZ NULL,
ADD COLUMN IF NOT EXISTS pickup_window_end TIMESTAMPTZ NULL;

-- 2. Backfill existing produce_requests from requested_pickup_at if available
UPDATE produce_requests
SET pickup_window_start = requested_pickup_at,
    pickup_window_end = requested_pickup_at + INTERVAL '2 hours'
WHERE pickup_window_start IS NULL AND requested_pickup_at IS NOT NULL;

-- 3. Create index on pickup window for produce_requests
CREATE INDEX IF NOT EXISTS ix_produce_requests_pickup_window 
ON produce_requests(pickup_window_start, pickup_window_end);

-- 4. Add rider_expected_pickup_at to trips
ALTER TABLE trips
ADD COLUMN IF NOT EXISTS rider_expected_pickup_at TIMESTAMPTZ NULL;

-- 5. Create index on trips rider_expected_pickup_at
CREATE INDEX IF NOT EXISTS ix_trips_expected_pickup 
ON trips(rider_expected_pickup_at);
"""

def run_migration():
    print("Running additive migration 003_pickup_window_and_rider_expected...")
    with engine.connect() as conn:
        for statement in MIGRATION_SQL.strip().split(";"):
            clean_stmt = statement.strip()
            if clean_stmt:
                conn.execute(text(clean_stmt))
        conn.commit()
    print("Migration 003_pickup_window_and_rider_expected executed successfully.")

if __name__ == "__main__":
    run_migration()
