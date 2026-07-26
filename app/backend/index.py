from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import os
from dotenv import load_dotenv
import logging
from pydantic import BaseModel

from livekit_integration.service import livekit_service
import config
from routes import adherence as adherence_routes
from routes import agent_tools as agent_tools_routes
from routes import auth as auth_routes
from routes import greetings as greetings_routes
from routes import links as links_routes
from routes import livekit as livekit_routes
from routes import mobile as mobile_routes
from routes import state as state_routes
from routes import user as user_routes

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Load environment variables from .env file
load_dotenv()

app = FastAPI(
    title="DoseLuma Backend",
    description="Medication adherence API with LiveKit voice agent",
    version="1.0.0"
)

# Add CORS middleware for mobile app - restrict to localhost in dev, specific domains in prod
allowed_origins = os.getenv("ALLOWED_ORIGINS", "http://localhost:*,http://127.0.0.1:*").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type", "Authorization"],
)

# Add security headers middleware
from starlette.middleware.base import BaseHTTPMiddleware

class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["X-XSS-Protection"] = "1; mode=block"
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        return response

app.add_middleware(SecurityHeadersMiddleware)

app.include_router(agent_tools_routes.router)
app.include_router(livekit_routes.router)
app.include_router(state_routes.router)
app.include_router(adherence_routes.router)
app.include_router(greetings_routes.router)
app.include_router(auth_routes.router)
app.include_router(links_routes.router)
app.include_router(mobile_routes.router)
app.include_router(user_routes.router)

###############################################################################
# Proactive scheduling engine
#
# Fires at each medication's scheduled time and dispatches the voice agent
# into the room automatically — the system-initiated call, independent of
# the patient opening the app. See scheduler.py.
###############################################################################

from scheduler import MedicationScheduler, recent_events  # noqa: E402

medication_scheduler = MedicationScheduler(
    dispatch=livekit_service.dispatch_agent,
    room_name=config.default_room(),
)


@app.on_event("startup")
async def _start_scheduler() -> None:
    medication_scheduler.start()


@app.on_event("shutdown")
async def _stop_scheduler() -> None:
    medication_scheduler.shutdown()


@app.get("/api/scheduler/events")
async def get_scheduler_events(limit: int = 20):
    """Recent proactive-initiation events (scheduled vs actual time, drift)."""
    return {"events": recent_events(limit=limit)}


@app.get("/")
def read_root():
    return {
        "service": "DoseLuma Backend",
        "version": app.version,
        "docs": "/docs",
        "health": "/api/health",
    }


@app.get("/api/health")
async def health_check():
    """Health check endpoint for mobile/web/CI probes."""
    from health import build_health_payload

    return build_health_payload(livekit_url=livekit_service.livekit_url)


class MedicationEntry(BaseModel):
    id: str | None = None
    name: str
    time: str


class RemindersBody(BaseModel):
    enabled: bool = True
    medications: list[MedicationEntry] = [
        MedicationEntry(name="Reminder 1", time="08:00"),
        MedicationEntry(name="Reminder 2", time="08:05"),
        MedicationEntry(name="Reminder 3", time="08:10"),
        MedicationEntry(name="Reminder 4", time="08:15"),
        MedicationEntry(name="Reminder 5", time="08:20"),
        MedicationEntry(name="Reminder 6", time="08:25"),
    ]


@app.get("/api/reminders")
async def get_reminders():
    """Medication reminder schedule for Expo local notifications."""
    from reminders import load_reminders

    return load_reminders()


@app.put("/api/reminders")
async def put_reminders(body: RemindersBody):
    from reminders import save_reminders

    try:
        doc = save_reminders(body.model_dump())
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    medication_scheduler.rebuild_jobs()
    return doc


# Voice agent greetings, real-time state (/ws/state), and adherence +
# caregiver alerts + intent classification now live in routes/greetings.py,
# routes/state.py, and routes/adherence.py — see the app.include_router
# calls above. LiveKit token issuance/dispatch (/api/livekit/*) lives in
# routes/livekit.py.
