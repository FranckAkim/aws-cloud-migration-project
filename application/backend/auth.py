"""Password hashing and stateless JWT authentication."""

import logging
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from pwdlib import PasswordHash

import db
from config import settings

logger = logging.getLogger("novatech")

ALGORITHM = "HS256"

password_hasher = PasswordHash.recommended()  # Argon2id
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")

# Verified against when the email doesn't exist, so a wrong email and a wrong
# password take the same time. Otherwise response timing reveals which emails
# have accounts.
_DUMMY_HASH = password_hasher.hash("timing-equaliser-not-a-real-password")


def hash_password(password: str) -> str:
    return password_hasher.hash(password)


def verify_password(password: str, hashed: str) -> bool:
    try:
        return password_hasher.verify(password, hashed)
    except Exception:  # malformed or legacy hash: treat as a failed login
        return False


def authenticate_user(email: str, password: str) -> dict | None:
    user = db.get_user_by_email(email.strip().lower())
    if user is None:
        verify_password(password, _DUMMY_HASH)
        return None
    if not verify_password(password, user["password_hash"]):
        return None
    return user


def create_access_token(user_id: int) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),
        "iat": now,
        "exp": now + timedelta(minutes=settings.jwt_expiration),
    }
    return jwt.encode(
        payload, settings.secret_key.get_secret_value(), algorithm=ALGORITHM
    )


def get_current_user_id(token: str = Depends(oauth2_scheme)) -> int:
    """FastAPI dependency: the verified user id, or a 401."""
    try:
        payload = jwt.decode(
            token,
            settings.secret_key.get_secret_value(),
            algorithms=[ALGORITHM],  # never trust the algorithm named in the token
        )
        return int(payload["sub"])
    except (jwt.PyJWTError, KeyError, ValueError):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
            headers={"WWW-Authenticate": "Bearer"},
        )
