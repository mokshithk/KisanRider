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

import httpx

import config
from email_templates import render_kisanrider_otp_email

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

    if not config.ENABLE_REAL_EMAIL_OTP:
        # Dev bypass — no email, no code check on verify. Return the code
        # so any caller who wants to log it can; the endpoint doesn't.
        return {"sent": False, "bypass": True, "code": code}

    if not _has_delivery_channel():
        print(f"[otp] Email delivery credentials missing for {email}")
        return {"sent": False, "bypass": False, "code": code}

    html_content, text_content = render_kisanrider_otp_email(
        otp_code=code,
        title="Verify Your KisanRider Account",
        subtitle="Account Registration",
        instruction="Please use the verification code below to complete your registration on KisanRider.",
        expiry_minutes=5,
    )

    try:
        _send_email(
            to_email=email,
            subject="KisanRider Verification Code",
            text_content=text_content,
            html_content=html_content,
        )
        return {"sent": True, "bypass": False, "code": code}
    except Exception as e:
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

    if not config.ENABLE_REAL_EMAIL_OTP:
        return {"sent": False, "bypass": True, "code": code}

    if not _has_delivery_channel():
        print(f"[otp] Email delivery credentials missing for password reset {email}")
        return {"sent": False, "bypass": False, "code": code}

    html_content, text_content = render_kisanrider_otp_email(
        otp_code=code,
        title="Reset Your KisanRider Password",
        subtitle="Password Recovery",
        instruction="You requested to reset your password. Use the verification code below to set a new password.",
        expiry_minutes=5,
    )

    try:
        _send_email(
            to_email=email,
            subject="KisanRider Password Reset Code",
            text_content=text_content,
            html_content=html_content,
        )
        return {"sent": True, "bypass": False, "code": code}
    except Exception as e:
        print(
            f"[otp] Password reset email send failed for {email}: "
            f"{type(e).__name__}: {e}"
        )
        return {"sent": False, "bypass": False, "code": code}


def _has_delivery_channel() -> bool:
    """Return True if at least one email delivery mechanism is configured."""
    if config.BREVO_API_KEY and (config.BREVO_SENDER_EMAIL or config.SMTP_EMAIL):
        return True
    if config.EMAIL_WEBHOOK_URL:
        return True
    return bool(config.SMTP_EMAIL and config.SMTP_PASSWORD)


def _send_via_brevo(
    to_email: str, subject: str, text_content: str, html_content: str
) -> None:
    sender_email = config.BREVO_SENDER_EMAIL or config.SMTP_EMAIL
    if not sender_email:
        raise RuntimeError("BREVO_SENDER_EMAIL or SMTP_EMAIL must be set for Brevo")

    resp = httpx.post(
        "https://api.brevo.com/v3/smtp/email",
        headers={
            "api-key": config.BREVO_API_KEY or "",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        json={
            "sender": {"name": "KisanRider", "email": sender_email},
            "to": [{"email": to_email}],
            "subject": subject,
            "htmlContent": html_content,
            "textContent": text_content,
        },
        timeout=15.0,
    )
    if resp.status_code >= 400:
        raise RuntimeError(f"Brevo API error {resp.status_code}: {resp.text}")


def _send_via_webhook(
    to_email: str, subject: str, text_content: str, html_content: str
) -> None:
    resp = httpx.post(
        config.EMAIL_WEBHOOK_URL or "",
        json={
            "to": to_email,
            "subject": subject,
            "text": text_content,
            "html": html_content,
        },
        follow_redirects=True,
        timeout=15.0,
    )
    if resp.status_code >= 400:
        raise RuntimeError(f"Email webhook error {resp.status_code}: {resp.text}")


def _send_email(to_email: str, subject: str, text_content: str, html_content: str) -> None:
    """
    Dispatch an OTP email over HTTPS (Brevo API or Webhook when configured,
    which works on Render Free Tier) or fall back to Gmail SMTP over SSL
    (for local development).
    """
    if config.BREVO_API_KEY:
        _send_via_brevo(to_email, subject, text_content, html_content)
        return

    if config.EMAIL_WEBHOOK_URL:
        _send_via_webhook(to_email, subject, text_content, html_content)
        return

    msg = MIMEMultipart("alternative")
    msg["From"] = config.SMTP_EMAIL or ""
    msg["To"] = to_email
    msg["Subject"] = subject
    msg.attach(MIMEText(text_content, "plain"))
    msg.attach(MIMEText(html_content, "html"))

    with smtplib.SMTP_SSL(
        config.SMTP_SERVER, _SMTP_SSL_PORT, timeout=_SMTP_TIMEOUT_SECONDS
    ) as server:
        server.login(config.SMTP_EMAIL or "", config.SMTP_PASSWORD or "")
        server.send_message(msg)