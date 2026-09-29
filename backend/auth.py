"""
Authentication primitives for KisanRider.

Provides:
  - password hashing / verification (bcrypt via passlib)
  - JWT access-token creation
  - FastAPI dependencies: get_current_user, require_role(...)
  - DEV_MODE gate + create_dev_token for local Swagger testing

Environment variables (loaded by main.py's python-dotenv bootstrap):
  - SECRET_KEY             signing key for JWTs; set a real one in prod
  - JWT_ALGORITHM          default "HS256"
  - ACCESS_TOKEN_MINUTES   default 1440 (24h)
  - ENVIRONMENT            "production" disables the dev-token route
"""

import os
from datetime import datetime, timedelta, timezone
from typing import Callable, Optional
from uuid import UUID

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from sqlalchemy.orm import Session

import crud
import models
from database import get_db


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SECRET_KEY: str = os.environ.get("SECRET_KEY", "dev-secret-change-me-in-production")
JWT_ALGORITHM: str = os.environ.get("JWT_ALGORITHM", "HS256")
ACCESS_TOKEN_EXPIRE_MINUTES: int = int(
    os.environ.get("ACCESS_TOKEN_MINUTES", str(60 * 24))
)

ENVIRONMENT: str = (os.environ.get("ENVIRONMENT") or "development").strip().lower()
# Any environment other than "production" is treated as dev. The dev-token
# route in main.py 404s when DEV_MODE is False — i.e. once you deploy with
# ENVIRONMENT=production, that route simply does not exist.
DEV_MODE: bool = ENVIRONMENT != "production"


# ---------------------------------------------------------------------------
# Password hashing
# ---------------------------------------------------------------------------

# bcrypt via passlib. On Python 3.13 + passlib 1.7.4 you may see a single
# cosmetic warning on first import:
#   (trapped) error reading bcrypt version
# It's passlib looking for `bcrypt.__about__.__version__`, which bcrypt 4.1+
# removed. Verification and hashing still work correctly; the warning is safe
# to ignore. If it bothers you, pin `bcrypt==4.0.1` in requirements.txt.
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(password: str) -> str:
    """bcrypt-hash a plaintext password. Returns the encoded hash string."""
    return pwd_context.hash(password)


def verify_password(plain: str, hashed: str) -> bool:
    """
    Constant-time bcrypt compare. Returns False on any malformed-hash error
    (a corrupt column value, a null, etc.) rather than letting passlib raise —
    the caller just sees "no match", which is what it should do.
    """
    try:
        return pwd_context.verify(plain, hashed)
    except Exception:
        return False


# ---------------------------------------------------------------------------
# JWT
# ---------------------------------------------------------------------------

def _create_token(
    user_id,
    expires_delta: timedelta,
    extra: Optional[dict] = None,
) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        # `sub` must be a string per RFC 7519; UUIDs are not JSON-native.
        "sub": str(user_id),
        "iat": int(now.timestamp()),
        "exp": int((now + expires_delta).timestamp()),
    }
    if extra:
        payload.update(extra)
    return jwt.encode(payload, SECRET_KEY, algorithm=JWT_ALGORITHM)


def create_access_token(user_id) -> str:
    """Issue a normal login token. Lifetime = ACCESS_TOKEN_EXPIRE_MINUTES."""
    return _create_token(user_id, timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES))


def create_dev_token(user_id) -> str:
    """
    Issue a short-lived token for local Swagger testing only. Marked with
    `"dev": true` so it's easy to spot in a decoded payload, and expires
    much sooner than a real login token.
    """
    return _create_token(user_id, timedelta(minutes=30), extra={"dev": True})


# ---------------------------------------------------------------------------
# FastAPI dependencies
# ---------------------------------------------------------------------------

# auto_error=False so a missing Authorization header produces our own 401
# with a clear detail message, not HTTPBearer's generic one.
_bearer = HTTPBearer(auto_error=False)


def get_current_user(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_bearer),
    db: Session = Depends(get_db),
) -> models.User:
    """
    Decode the Bearer JWT, load the referenced user, return the ORM row.

    Returns 401 in every failure mode — missing header, malformed token,
    expired token, `sub` missing, `sub` not a UUID, or the user id no longer
    exists in the DB. The client can't distinguish these on purpose; the
    correct reaction to all of them is "log in again".
    """
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Not authenticated",
        headers={"WWW-Authenticate": "Bearer"},
    )

    if credentials is None or not credentials.credentials:
        raise unauthorized

    token = credentials.credentials
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[JWT_ALGORITHM])
        sub = payload.get("sub")
        if not sub:
            raise unauthorized
        user_id = UUID(str(sub))
    except (JWTError, ValueError):
        raise unauthorized

    user = crud.get_user_by_id(db, user_id)
    if user is None:
        raise unauthorized
    return user


def require_role(role: str) -> Callable[..., models.User]:
    """
    Dependency factory. Usage:

        @app.get("/x")
        def endpoint(user: models.User = Depends(auth.require_role("FARMER"))):
            ...

    Returns a dependency that first resolves `get_current_user` (so an
    unauthenticated request 401s before the role is even examined), then
    checks `user.role == role`. A mismatch raises 403.
    """
    def _dependency(
        current_user: models.User = Depends(get_current_user),
    ) -> models.User:
        if current_user.role != role:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"This endpoint requires role: {role}",
            )
        return current_user

    return _dependency