"""Simple password-based session auth."""

import os
import secrets
from fastapi import Request, HTTPException

_sessions: set[str] = set()
PASSWORD = os.environ.get("PASSWORD", "orbit")


def check_password(password: str) -> str | None:
    """Return a session token if password matches, else None."""
    if password == PASSWORD:
        token = secrets.token_urlsafe(32)
        _sessions.add(token)
        return token
    return None


def require_auth(request: Request):
    """FastAPI dependency — raises 401 if no valid session."""
    token = request.cookies.get("session") or request.query_params.get("token")
    if not token or token not in _sessions:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return token
