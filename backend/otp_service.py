"""
OTP generation, storage, and email dispatch for the signup flow.

Storage is an in-memory dict: fine for local dev and single-process
deployments, useless behind multiple uvicorn workers or a load balancer.
Swap for Redis the day you deploy more than one instance.

Email delivery uses smtplib — synchronous, but FastAPI runs the sync `def`
endpoints that call it inside a threadpool, so it won't block the event
loop. A slow SMTP handshake (~1-2s) just occupies one worker thread; on
the scale this MVP operates at, that's a non-issue.
"""

import random
import smtplib
import time
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

from config import (
    ENABLE_REAL_EMAIL_OTP,
    SMTP_EMAIL,
    SMTP_PASSWORD,
    SMTP_SERVER,
)

# Code lifetime. 5 minutes is the industry-standard sweet spot — long enough
# that a user fumbling for their inbox doesn't time out, short enough that a
# leaked code is useless by the time an attacker gets to it.
_OTP_TTL_SECONDS = 300

# SMTP over SSL uses port 465. This replaces the earlier 587 + STARTTLS
# setup, which consistently timed out during the DATA phase on this
# network (SMTPServerDisconnected: Connection unexpectedly closed) even
# though the login step succeeded. Port 465 performs the TLS handshake
# before any SMTP dialogue, so the whole session is inside TLS — that's
# what makes it survive the firewall/middlebox behavior we were hitting.
_SMTP_SSL_PORT = 465
_SMTP_TIMEOUT_SECONDS = 30


# email (lowercased) → (code, expires_at_unix_seconds)
# A dict is not thread-safe across workers. Single-process dev is fine.
#
# The signup flow and the password-reset flow use SEPARATE stores so a
# code issued for one flow can never be replayed against the other. If a
# user has an in-flight signup OTP and then requests a password reset,
# each code only unlocks its own endpoint.
_otp_store: dict[str, tuple[str, float]] = {}
_password_reset_otp_store: dict[str, tuple[str, float]] = {}


def _normalize(email: str) -> str:
    """
    Lowercase + trim so "User@Example.com " and "user@example.com" resolve
    to the same stored code. Email is case-insensitive in practice, and
    this avoids a support ticket like "I typed a capital letter".
    """
    return email.strip().lower()


def _generate_code() -> str:
    """4-digit numeric code, zero-padded so '0001' is valid."""
    return f"{random.randint(0, 9999):04d}"


def _store_otp(email: str, code: str) -> None:
    _otp_store[_normalize(email)] = (code, time.time() + _OTP_TTL_SECONDS)


def _store_password_reset_otp(email: str, code: str) -> None:
    _password_reset_otp_store[_normalize(email)] = (
        code,
        time.time() + _OTP_TTL_SECONDS,
    )


def verify_email_otp_code(email: str, submitted: str) -> bool:
    """
    Check `submitted` against the signup code stored for `email`. Returns
    False on missing entry, expiry, or mismatch. A successful verification
    consumes the code — a second call with the same OTP returns False.
    That's the right behavior: an OTP is single-use.
    """
    key = _normalize(email)
    entry = _otp_store.get(key)
    if entry is None:
        return False

    code, expires_at = entry
    if time.time() > expires_at:
        _otp_store.pop(key, None)
        return False

    if submitted.strip() != code:
        return False

    _otp_store.pop(key, None)
    return True


def verify_password_reset_otp_code(email: str, submitted: str) -> bool:
    """
    Same semantics as verify_email_otp_code, but against the password-reset
    store. Kept separate so a signup OTP cannot be replayed as a reset OTP
    (or vice versa).
    """
    key = _normalize(email)
    entry = _password_reset_otp_store.get(key)
    if entry is None:
        return False

    code, expires_at = entry
    if time.time() > expires_at:
        _password_reset_otp_store.pop(key, None)
        return False

    if submitted.strip() != code:
        return False

    _password_reset_otp_store.pop(key, None)
    return True


def issue_and_send_email_otp(email: str) -> dict:
    """
    Generate a code, store it, and (when real OTP is enabled) email it.

    Returns a dict the caller uses to shape the HTTP response:
        {
          "sent":   bool,   # was an email actually dispatched?
          "bypass": bool,   # is dev bypass active?
          "code":   str|None,  # the generated code, only when NOT sent
        }

    Callers should raise 502 when `sent` is False and `bypass` is False —
    i.e. the user asked for real OTP but SMTP delivery failed.
    """
    code = _generate_code()
    _store_otp(email, code)

    if not ENABLE_REAL_EMAIL_OTP:
        # Dev bypass — no email, no code check on verify. Return the code
        # so any caller who wants to log it can; the endpoint doesn't.
        return {"sent": False, "bypass": True, "code": code}

    if not SMTP_EMAIL or not SMTP_PASSWORD:
        # Real OTP requested but no SMTP credentials configured. Log the
        # code (so a developer can still complete the flow from the
        # terminal) and report `sent=False` — the caller will 502.
        print(f"[otp] SMTP credentials missing — code for {email} is {code}")
        return {"sent": False, "bypass": False, "code": code}

    try:
        _send_email(
            to_email=email,
            subject="KisanRider Verification Code",
            body=(
                "Your KisanRider verification code is:\n\n"
                f"    {code}\n\n"
                "This code expires in 5 minutes. If you didn't request it, "
                "you can safely ignore this email."
            ),
        )
        return {"sent": True, "bypass": False, "code": code}
    except Exception as e:
        # Swallow the exception and surface failure as a boolean — the
        # caller doesn't need a traceback, just "did it work". The code
        # is logged so the developer can recover manually if this is a
        # transient SMTP hiccup.
        print(f"[otp] Email send failed for {email}: {type(e).__name__}: {e}")
        return {"sent": False, "bypass": False, "code": code}


def issue_and_send_password_reset_otp(email: str) -> dict:
    """
    Generate and (when real OTP is enabled) email a password-reset code.

    Mirrors issue_and_send_email_otp — same return shape, same dev bypass
    semantics — but stores under the password-reset namespace and sends a
    reset-specific subject/body. Kept parallel rather than parameterized so
    each flow's subject line is impossible to mix up.
    """
    code = _generate_code()
    _store_password_reset_otp(email, code)

    if not ENABLE_REAL_EMAIL_OTP:
        return {"sent": False, "bypass": True, "code": code}

    if not SMTP_EMAIL or not SMTP_PASSWORD:
        print(
            f"[otp] SMTP credentials missing — password reset code for "
            f"{email} is {code}"
        )
        return {"sent": False, "bypass": False, "code": code}

    try:
        _send_email(
            to_email=email,
            subject="KisanRider Password Reset Code",
            body=(
                "Your KisanRider password reset code is:\n\n"
                f"    {code}\n\n"
                "This code expires in 5 minutes. If you didn't request a "
                "password reset, you can safely ignore this email — your "
                "current password will keep working."
            ),
        )
        return {"sent": True, "bypass": False, "code": code}
    except Exception as e:
        print(
            f"[otp] Password reset email send failed for {email}: "
            f"{type(e).__name__}: {e}"
        )
        return {"sent": False, "bypass": False, "code": code}


def _send_email(to_email: str, subject: str, body: str) -> None:
    """
    Open an SMTP-over-SSL session, authenticate, and send a plaintext
    message. Raises smtplib.SMTPException (or a subclass) on any failure,
    including auth rejection and network timeouts.

    Uses port 465 (implicit TLS) rather than 587 (STARTTLS). On the
    network this was developed on, 587 with STARTTLS authenticated fine
    but then timed out during the message body transfer, while 465 with
    SMTP_SSL delivers reliably. Google supports both ports, so nothing
    is lost by preferring the one that works here.

    For Gmail, SMTP_PASSWORD must be a 16-character App Password with
    spaces stripped. Using the account's regular password with 2FA
    enabled produces SMTPAuthenticationError (535, b'5.7.8 ...').
    """
    msg = MIMEMultipart()
    msg["From"] = SMTP_EMAIL
    msg["To"] = to_email
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain"))

    with smtplib.SMTP_SSL(
        SMTP_SERVER, _SMTP_SSL_PORT, timeout=_SMTP_TIMEOUT_SECONDS
    ) as server:
        server.login(SMTP_EMAIL, SMTP_PASSWORD)
        server.send_message(msg)