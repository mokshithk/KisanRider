"""
Initial Admin Provisioning CLI for KisanRider.

Usage:
    python bootstrap_admin.py

Safely provisions the very first ADMIN account in the system.
Guarantees:
- Refuses to run if any ADMIN already exists in the database.
- Secure, hidden password input via Python `getpass` (no echo) in interactive sessions.
- Gracefully accepts piped stdin when running in automated setup / CI.
- Hashes password using the project's established bcrypt implementation.
- Logs the bootstrap action in admin_activity_logs.
- Does not modify or disrupt existing FARMER or RIDER accounts.
"""

import getpass
import io
import re
import sys
from uuid import uuid4

# Ensure UTF-8 output even on legacy Windows code pages
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from sqlalchemy import func
from database import SessionLocal
import models
import pools.models  # noqa: F401 -- registers Pool on Base.metadata
import auth
from admin_router import log_activity


EMAIL_REGEX = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _secure_password_prompt(prompt_text: str) -> str:
    """Prompt for password: uses getpass in interactive TTY, falls back to stdin if piped."""
    if sys.stdin.isatty():
        return getpass.getpass(prompt_text)
    else:
        print(prompt_text, end="", flush=True)
        line = sys.stdin.readline()
        if not line:
            raise EOFError("No input received.")
        return line.rstrip("\r\n")


def bootstrap_initial_admin():
    print("=" * 60)
    print(" KisanRider — Initial Administrator Provisioning")
    print("=" * 60)

    db = SessionLocal()
    try:
        # 1. Check if an admin already exists
        existing_admin_count = (
            db.query(func.count(models.User.id))
            .filter(models.User.role == "ADMIN")
            .scalar()
            or 0
        )

        if existing_admin_count > 0:
            print("\n[!] ABORTED: An Administrator account already exists in this database.")
            print("    For security reasons, bootstrap_admin.py only provisions the first admin.")
            print("    To add additional administrators, log in to the KisanRider Admin Web")
            print("    and use the secure Admin Management invitation workflow.\n")
            sys.exit(1)

        # 2. Input
        print("\nProvisioning first Admin account. Please provide details:")
        
        # Name
        if sys.stdin.isatty():
            full_name = input("Enter Admin Full Name: ").strip()
            while not full_name or len(full_name) < 2:
                print("Name must be at least 2 characters.")
                full_name = input("Enter Admin Full Name: ").strip()
        else:
            full_name = sys.stdin.readline().strip()

        # Email
        if sys.stdin.isatty():
            email = input("Enter Admin Email Address: ").strip().lower()
            while not email or not EMAIL_REGEX.match(email):
                print("Invalid email format.")
                email = input("Enter Admin Email Address: ").strip().lower()
        else:
            email = sys.stdin.readline().strip().lower()

        # Check if email is already taken by Farmer or Rider
        existing_user = db.query(models.User).filter(func.lower(models.User.email) == email).first()
        if existing_user:
            print(f"\n[!] ABORTED: A user with email '{email}' already exists with role: {existing_user.role}.")
            print("    Please use a unique email address for the administrator.\n")
            sys.exit(1)

        # Secure password entry
        while True:
            password = _secure_password_prompt("Enter Admin Password (min 8 characters): ")
            if len(password) < 8:
                print("Password must be at least 8 characters long.")
                if not sys.stdin.isatty():
                    sys.exit(1)
                continue
            confirm = _secure_password_prompt("Confirm Admin Password: ")
            if password != confirm:
                print("Passwords do not match. Please try again.")
                if not sys.stdin.isatty():
                    sys.exit(1)
                continue
            break

        # 3. Create initial Admin
        print("\nEncrypting password and registering Administrator...")
        password_hash = auth.hash_password(password)

        admin_user = models.User(
            id=uuid4(),
            email=email,
            full_name=full_name,
            role="ADMIN",
            password_hash=password_hash,
            is_active=True,
            is_verified=True,
            state="Karnataka",
        )
        db.add(admin_user)

        # 4. Audit Log
        log_activity(
            db,
            admin=admin_user,
            action="BOOTSTRAP_INITIAL_ADMIN",
            module="AUTH",
            record_id=str(admin_user.id),
            description=f"Initial system administrator '{full_name}' ({email}) provisioned via CLI bootstrap.",
            changes={"email": email, "full_name": full_name, "role": "ADMIN"},
        )

        db.commit()
        db.refresh(admin_user)

        print("\n[+] SUCCESS: Initial Administrator account created successfully!")
        print(f"    Name:  {admin_user.full_name}")
        print(f"    Email: {admin_user.email}")
        print(f"    Role:  {admin_user.role}")
        print("    You may now launch the Admin Web and log in with these credentials.\n")

    except Exception as e:
        db.rollback()
        print(f"\n[!] Unexpected error during bootstrap: {e}\n")
        sys.exit(1)
    finally:
        db.close()


if __name__ == "__main__":
    bootstrap_initial_admin()
