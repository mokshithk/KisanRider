# backend/fix_db.py
from database import engine
from sqlalchemy import text

print("Connecting to database using your existing 'database.py' settings...")

with engine.connect() as conn:
    try:
        # Force add the missing column
        conn.execute(text(
            "ALTER TABLE produce_requests "
            "ADD COLUMN IF NOT EXISTS cancellation_reason VARCHAR(500);"
        ))
        conn.commit()
        print("✅ SUCCESS: Added 'cancellation_reason' column to produce_requests table.")
    except Exception as e:
        print(f"❌ ERROR: {e}")