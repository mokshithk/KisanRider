import os
from typing import Optional
from uuid import UUID

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from sqlalchemy.orm import Session
from dotenv import load_dotenv

import crud
import models
from database import get_db

# Automatically load variables from .env file
load_dotenv()

SUPABASE_JWT_SECRET = os.getenv("SUPABASE_JWT_SECRET")
JWT_ALGORITHM = "HS256"
JWT_AUDIENCE = "authenticated"  # Supabase's standard audience claim for logged-in users

oauth2_scheme = HTTPBearer(auto_error=True)


def _unauthorized(detail: str = "Could not validate credentials") -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> models.User:
    """
    Decode + verify the Supabase JWT, then load the matching row from our
    own `users` table via its `sub` claim.
    """
    if not SUPABASE_JWT_SECRET:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="SUPABASE_JWT_SECRET environment variable is missing on server.",
        )

    token = credentials.credentials

    try:
        payload = jwt.decode(
            token,
            SUPABASE_JWT_SECRET,
            algorithms=[JWT_ALGORITHM],
            audience=JWT_AUDIENCE,
        )
    except JWTError:
        raise _unauthorized()

    sub: Optional[str] = payload.get("sub")
    if not sub:
        raise _unauthorized("Token missing 'sub' claim")

    try:
        user_id = UUID(sub)
    except ValueError:
        raise _unauthorized("Token 'sub' claim is not a valid UUID")

    # Fetch user row from DB (supports get_user or get_user_by_id in crud.py)
    fetch_user = getattr(crud, "get_user_by_id", getattr(crud, "get_user", None))
    user = fetch_user(db, user_id) if fetch_user else None

    if not user:
        raise _unauthorized("No user found for this token")

    return user


def require_role(*allowed_roles: str):
    """
    Dependency factory restricting endpoints to specific roles (FARMER / RIDER).
    Returns 403 FORBIDDEN if identity checks out but role permissions fail.
    """
    def _dependency(current_user: models.User = Depends(get_current_user)) -> models.User:
        if current_user.role not in allowed_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"This action requires role: {', '.join(allowed_roles)}",
            )
        return current_user

    return _dependency