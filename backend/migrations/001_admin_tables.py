"""
Additive migration:
- Adds is_active to users table
- Creates admin_invitations table
- Creates admin_activity_logs table
Non-destructive: Uses ADD COLUMN IF NOT EXISTS and CREATE TABLE IF NOT EXISTS.
"""

import sys
from pathlib import Path
from sqlalchemy import text

# Ensure backend root is on sys.path
backend_dir = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(backend_dir))

from database import engine

MIGRATION_SQL = """
-- 1. Add is_active column to users table
ALTER TABLE users 
ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE;

-- 2. Create admin_invitations table
CREATE TABLE IF NOT EXISTS admin_invitations (
    id UUID PRIMARY KEY,
    email VARCHAR(255) NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    token_hash VARCHAR(64) UNIQUE NOT NULL,
    invited_by_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    accepted_at TIMESTAMPTZ NULL
);

CREATE INDEX IF NOT EXISTS ix_admin_invitations_email ON admin_invitations(email);
CREATE INDEX IF NOT EXISTS ix_admin_invitations_token_hash ON admin_invitations(token_hash);

-- 3. Create admin_activity_logs table
CREATE TABLE IF NOT EXISTS admin_activity_logs (
    id UUID PRIMARY KEY,
    admin_id UUID REFERENCES users(id) ON DELETE SET NULL,
    admin_email VARCHAR(255) NOT NULL,
    admin_name VARCHAR(100) NOT NULL,
    action VARCHAR(100) NOT NULL,
    module VARCHAR(50) NOT NULL,
    record_id VARCHAR(100) NULL,
    description TEXT NOT NULL,
    changes TEXT NULL,
    ip_address VARCHAR(50) NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_admin_activity_logs_action ON admin_activity_logs(action);
CREATE INDEX IF NOT EXISTS ix_admin_activity_logs_module ON admin_activity_logs(module);
CREATE INDEX IF NOT EXISTS ix_admin_activity_logs_record_id ON admin_activity_logs(record_id);
CREATE INDEX IF NOT EXISTS ix_admin_activity_logs_created_at ON admin_activity_logs(created_at);
"""

def run_migration():
    print("Running additive migration 001_admin_tables...")
    with engine.connect() as conn:
        for statement in MIGRATION_SQL.strip().split(";"):
            clean_stmt = statement.strip()
            if clean_stmt:
                conn.execute(text(clean_stmt))
        conn.commit()
    print("Migration 001_admin_tables executed successfully.")

if __name__ == "__main__":
    run_migration()
