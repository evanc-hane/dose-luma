"""Name-based auth — no passwords. See users.py."""

from __future__ import annotations

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/api/auth", tags=["auth"])


class RegisterRequest(BaseModel):
    username: str
    display_name: str
    phone: str = ""
    password: str = ""  # accepted but ignored — no passwords
    role: str = "patient"


class RefreshRequest(BaseModel):
    token: str


class AuthResponse(BaseModel):
    user_id: str
    display_name: str
    role: str
    phone: str | None = None
    token: str
    api_key: str | None = None


@router.post("/register", response_model=AuthResponse)
async def register(body: RegisterRequest):
    """Find-or-create a user by name. No password is checked or stored."""
    import users as users_mod

    try:
        user = users_mod.register_or_login(
            username=body.username,
            display_name=body.display_name,
            phone=body.phone,
            role=body.role,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return AuthResponse(
        user_id=user["id"],
        display_name=user["display_name"],
        role=user["role"],
        phone=user.get("phone"),
        token=user["token"],
    )


@router.post("/refresh", response_model=AuthResponse)
async def refresh(body: RefreshRequest):
    """Look up the session by its current token. Tokens don't expire today,
    so this just re-confirms the session rather than rotating anything."""
    import users as users_mod

    user = users_mod.find_by_token(body.token)
    if not user:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    return AuthResponse(
        user_id=user["id"],
        display_name=user["display_name"],
        role=user["role"],
        phone=user.get("phone"),
        token=user["token"],
    )
