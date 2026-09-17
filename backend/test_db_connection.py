"""
Standalone Supabase/PostGIS connection tester.
Run: python test_db_connection.py
Checks env-var overrides, parses the URL safely, and tests both
raw psycopg2 and SQLAlchemy connections.
"""

import os
import sys
from urllib.parse import quote_plus

from dotenv import load_dotenv

# --- Step 0: detect the #1 cause of this bug: a stale shell env var ---
pre_existing = os.environ.get("DATABASE_URL")
if pre_existing:
    print("⚠️  DATABASE_URL was already set in your shell BEFORE loading .env:")
    print(f"    {pre_existing}")
    print("    load_dotenv() will NOT override this unless you pass override=True.\n")

load_dotenv(override=True)

DATABASE_URL = os.getenv("DATABASE_URL")

# Build from split fields instead, if you're using that pattern:
if not DATABASE_URL and os.getenv("DB_USER"):
    DATABASE_URL = (
        f"postgresql://{os.getenv('DB_USER')}:{quote_plus(os.getenv('DB_PASSWORD', ''))}"
        f"@{os.getenv('DB_HOST')}:{os.getenv('DB_PORT', '5432')}/{os.getenv('DB_NAME', 'postgres')}"
    )

if not DATABASE_URL:
    sys.exit("❌ No DATABASE_URL (or DB_* fields) found. Check your .env file.")

# --- Step 1: parse and sanity-check the URL BEFORE connecting ---
from sqlalchemy.engine import make_url

try:
    parsed = make_url(DATABASE_URL)
except Exception as e:
    sys.exit(f"❌ URL failed to parse at all: {e}")

masked_password = "***" if parsed.password else "(none)"
print("Parsed connection components:")
print(f"  driver:   {parsed.drivername}")
print(f"  username: {parsed.username}")
print(f"  password: {masked_password}")
print(f"  host:     {parsed.host}")
print(f"  port:     {parsed.port}")
print(f"  database: {parsed.database}\n")

if parsed.host and "@" in parsed.host:
    sys.exit(
        f"❌ The parsed host still contains '@': '{parsed.host}'\n"
        "   This means the password wasn't percent-encoded, or the .env value "
        "has a formatting issue (quotes, stray characters, wrong scheme)."
    )

# --- Step 2: raw psycopg2 connection test ---
print("Testing raw psycopg2 connection...")
try:
    import psycopg2

    conn = psycopg2.connect(
        dbname=parsed.database,
        user=parsed.username,
        password=parsed.password,
        host=parsed.host,
        port=parsed.port,
        connect_timeout=10,
    )
    cur = conn.cursor()
    cur.execute("SELECT version();")
    print(f"✅ psycopg2 connected. {cur.fetchone()[0]}")
    cur.close()
    conn.close()
except Exception as e:
    print(f"❌ psycopg2 connection failed: {e}\n")

# --- Step 3: SQLAlchemy + PostGIS check ---
print("\nTesting SQLAlchemy connection + PostGIS...")
try:
    from sqlalchemy import create_engine, text

    engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    with engine.connect() as conn:
        result = conn.execute(text("SELECT PostGIS_Version();")).fetchone()
        print(f"✅ SQLAlchemy connected. PostGIS version: {result[0]}")
except Exception as e:
    print(f"❌ SQLAlchemy connection failed: {e}")
    print(
        "\nIf this says 'could not translate host name', and the host looks "
        "correct above, it's almost certainly an IPv6-reachability issue with "
        "the direct connection host — switch to the session/transaction pooler."
    )