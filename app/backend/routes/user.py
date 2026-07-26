"""Logged-in user's own profile + push token registration."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

router = APIRouter(prefix="/api", tags=["user"])


def _authed_user(x_user_token: str | None) -> dict[str, Any]:
    import users as users_mod

    if not x_user_token:
        raise HTTPException(status_code=401, detail="Missing session token")
    user = users_mod.find_by_token(x_user_token)
    if not user:
        raise HTTPException(status_code=401, detail="Invalid or expired session")
    return user


class ProfileUpdateRequest(BaseModel):
    phone: str


@router.post("/user/profile")
async def update_profile(body: ProfileUpdateRequest, x_user_token: str | None = Header(default=None)):
    import users as users_mod

    user = _authed_user(x_user_token)
    users_mod.update_phone(user["id"], body.phone)
    return {}


class PushTokenRequest(BaseModel):
    user_id: str
    device_token: str
    device_id: str = ""


@router.post("/users/push-token")
async def register_push_token(body: PushTokenRequest, x_user_token: str | None = Header(default=None)):
    import users as users_mod

    user = _authed_user(x_user_token)
    users_mod.update_push_token(user["id"], body.device_token)
    return {}
