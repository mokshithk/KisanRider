"""
Supabase JWT authentication for KisanRider.

Verifies the JWT that Supabase Auth issues to the frontend (sent by the
client as `Authorization: Bearer <token>`) and resolves it to our own
`users` row, so endpoints can trust `current_user.id` / `current_user.role`
instead of accepting a farmer_id/rider_id straight from the request.

IMPORTANT — which signing mode is your Supabase project on?
Supabase JWTs are verified one of two ways, and it depends on a setting in
your project (Project Settings -> Data API -> JWT Settings):

1. **Legacy HS256 shared secret** — every project created before Supabase's
   2024/2025 migration to asymmetric keys defaults to this. You verify with
   a single symmetric secret (`SUPABASE_JWT_SECRET`). This is what's
   implemented below.
2. **Asymmetric signing keys (ES256/RS256)** — newer projects (and any
   project you've rotated onto the new key system) sign with a private key
   and publish the public half at
   `{SUPABASE_URL}/auth/v1/.well-known/jwks.json`. A shared secret can't
   verify these tokens at all — `jwt.decode()` will fail with a signature
   error that looks identical to "invalid token" from the outside.

   If that's your project, swap the verification block for a JWKS-based
   check instead (fetch + cache the JWKS, pick the key matching the
   token's `kid` header, verify with `jose.jwk.construct(...)`).

Check your project's JWT Settings before deploying this to confirm which
of the two you're actually on.

Env vars required:
- SUPABASE_JWT_SECRET: Project Settings -> Data API -> JWT Settings -> JWT Secret
  (only applies to mode 1 above)
"""

import os
from datetime import datetime, timedelta
from typing import Optional
from uuid import UUID

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from sqlalchemy.orm import Session

import crud
import models
from database import get_db

SUPABASE_JWT_SECRET = os.environ["SUPABASE_JWT_SECRET"]
JWT_ALGORITHM = "HS256"
JWT_AUDIENCE = "authenticated"  # Supabase's standard audience claim for a logged-in user

# Gates create_dev_token()/the /auth/dev-token endpoint. This mints a valid,
# signed access token for *any* user id with no password check at all — it
# is a deliberate full auth bypass, scoped to local development only. It
# must never be reachable with ENVIRONMENT=production; see create_dev_token
# below for why disabling it isn't optional.
DEV_MODE = os.environ.get("ENVIRONMENT", "development").lower() != "production"

# HTTPBearer, not OAuth2PasswordBearer: tokens are issued by Supabase Auth
# directly (the client talks to Supabase, not to this API, to log in), so
# there's no local /token endpoint for OAuth2PasswordBearer's password-grant
# flow to point at. HTTPBearer just expects "Authorization: Bearer <token>".
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
    own `users` table via its `sub` claim (Supabase's auth user id, which
    KisanRider also uses as `users.id`).

    Deliberately returns the DB row, not the raw token claims: our app-level
    role (FARMER/RIDER) lives in `users.role`, which is authoritative — it's
    what registration set and what every existing endpoint already checks.
    Supabase's own `role` claim in the token is a different, auth-level
    concept (almost always just "authenticated") and isn't the same thing;
    trusting a role claim from the token instead of the DB would let a stale
    or forged claim bypass an app-level permission check.
    """
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

    user = crud.get_user_by_id(db, user_id)
    if not user:
        raise _unauthorized("No user found for this token")

    return user


def require_role(*allowed_roles: str):
    """
    Dependency factory for endpoints restricted to specific app roles:

        @app.post("/produce-requests/")
        def create(
            ...,
            current_user: models.User = Depends(auth.require_role("FARMER")),
        ):
            ...

    A valid-but-wrong-role token gets 403 (the identity checks out, the
    permission doesn't), not 401 (which means the identity itself is
    unverified/missing) — keeping that distinction is what lets a frontend
    tell "log in again" apart from "you're logged in as the wrong kind of
    user for this action".
    """

    def _dependency(current_user: models.User = Depends(get_current_user)) -> models.User:
        if current_user.role not in allowed_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"This action requires role: {', '.join(allowed_roles)}",
            )
        return current_user

    return _dependency


def create_dev_token(user_id: UUID, expires_minutes: int = 60) -> str:
    """
    Mint a JWT for `user_id` signed with the same secret get_current_user
    verifies against, so it satisfies auth.get_current_user exactly like a
    real Supabase-issued token would — no Supabase call, no password.

    DO NOT expose whatever calls this outside local development. It's a
    complete authentication bypass: anyone who can hit the endpoint that
    calls this can become any user in the database just by knowing (or
    guessing/enumerating) their UUID. That's why this function refuses to
    run at all unless DEV_MODE is True — the caller (the /auth/dev-token
    endpoint in main.py) checks DEV_MODE too, but the check is duplicated
    here on purpose, so this function is unsafe to call by construction,
    not just unsafe because of how one call site happens to guard it.
    """
    if not DEV_MODE:
        raise RuntimeError(
            "create_dev_token() is disabled: ENVIRONMENT=production. "
            "This function issues unauthenticated access tokens and must "
            "never run outside local development."
        )

    now = datetime.utcnow()
    payload = {
        "sub": str(user_id),
        "aud": JWT_AUDIENCE,
        "role": "authenticated",
        "iat": now,
        "exp": now + timedelta(minutes=expires_minutes),
    }
    return jwt.encode(payload, SUPABASE_JWT_SECRET, algorithm=JWT_ALGORITHM)