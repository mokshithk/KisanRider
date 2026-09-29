"""
Centralized runtime configuration.

Reads from environment (populated by python-dotenv in main.py's bootstrap).
Every other module should import from here rather than calling os.environ
directly, so the set of tunable knobs lives in one place.
"""

import os
from dotenv import load_dotenv

# load_dotenv is idempotent — calling it here AND in main.py is safe. This
# is the single place that guarantees the values below are populated no
# matter which module imports first.
load_dotenv()


def _bool_env(name: str, default: bool) -> bool:
    """
    Parse a boolean env var the way humans actually write them: "1", "true",
    "yes", "on" all mean True; anything else (including unset) falls back to
    the default. Avoids the classic bug where `bool("false") == True`.
    """
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


# ----- Signup OTP behavior ------------------------------------------------
# True  → real email is sent, OTP is validated against the stored code.
# False → dev bypass: no email, any 4-8 digit string verifies.
ENABLE_REAL_EMAIL_OTP: bool = _bool_env("ENABLE_REAL_EMAIL_OTP", default=True)

# SMTP credentials. When ENABLE_REAL_EMAIL_OTP is True and any of these is
# missing, otp_service logs the generated code to stdout instead of sending
# — useful for local dev without a working mail server.
SMTP_EMAIL: str | None = os.environ.get("SMTP_EMAIL") or None
SMTP_PASSWORD: str | None = os.environ.get("SMTP_PASSWORD") or None
SMTP_SERVER: str = (os.environ.get("SMTP_SERVER") or "smtp.gmail.com").strip()
# Port as int. 587 → STARTTLS (the standard); 465 → implicit TLS.
SMTP_PORT: int = int(os.environ.get("SMTP_PORT") or "587")