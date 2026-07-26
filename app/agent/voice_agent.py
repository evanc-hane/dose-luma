"""
LiveKit Voice Agent Worker — medication adherence dialogue.

Fully local/self-hosted voice stack. Providers come from root config.json
(via app/backend/config.py). Secrets (LiveKit creds) stay in env.

Both the mobile app and talk.html join the same LiveKit room after calling
POST /api/livekit/connect (which also dispatches this agent).

Run alongside the FastAPI backend (from repo root):
    PYTHONPATH=app/backend uv run --project app/backend python app/agent/voice_agent.py dev
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# Shared config lives in app/backend/
_BACKEND_DIR = Path(__file__).resolve().parents[1] / "backend"
if str(_BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(_BACKEND_DIR))

from dotenv import load_dotenv
from livekit.agents import (
    Agent,
    AgentSession,
    AgentStateChangedEvent,
    JobContext,
    MetricsCollectedEvent,
    RunContext,
    UserStateChangedEvent,
    WorkerOptions,
    cli,
    function_tool,
    metrics,
)

import config

_REPO_ROOT = Path(__file__).resolve().parents[2]
load_dotenv(_REPO_ROOT / ".env")
load_dotenv(_BACKEND_DIR / ".env")

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("voice-agent")

# Default end-to-end latency budget (ms), logged for benchmarking.
_LATENCY_BUDGET_MS = 400.0

_BACKEND_API = (os.getenv("ALI_BACKEND_URL") or "http://127.0.0.1:8801").rstrip("/")

# Spoken persona — keep this warm and human. Never leak stack/model details.
ALI_INSTRUCTIONS = (
    "You are ALI, a warm, friendly, empathetic companion for an older adult "
    "— not a medication checklist. Talk like a kind, patient friend who "
    "genuinely cares how they're doing. Use everyday words. Keep every "
    "reply to 1–2 short sentences. Adapt to their mood — if they sound "
    "cheerful, be upbeat; if they sound tired or low, slow down and be gentle. "
    ""
    "Whether you bring up medication at all depends on who started this "
    "call — see the note below for which situation you're in right now. "
    "When it's not the moment for medication, just be a companion: ask "
    "about their day, listen, enjoy their company, chat about whatever they "
    "want. If something worth remembering comes up (something they like, "
    "how they've been feeling, a plan they mentioned), jot it down with "
    "manage_notes so you can pick it back up next time — do this naturally, "
    "without narrating that you're taking notes. "
    ""
    "If they want to learn or practice a language (English, Chinese, "
    "Japanese, or any other), follow through as their language-learning "
    "companion, not just a one-off chat: check manage_notes (action='read', "
    "no note_id, to list your notes) at the start of companion time for an "
    "existing note about their language learning, so you continue where you "
    "left off — a word or phrase they were working on, what you covered "
    "last time — instead of starting over. Actually teach and practice with "
    "them (simple words, short phrases, gentle correction), and update the "
    "note with what you covered so next time picks up naturally. This is "
    "the one deliberate exception to always answering in their own "
    "language — while practicing together, use the language they're "
    "learning for the words/phrases themselves. "
    ""
    "After the user answers about a medication, call report_medication_status "
    "with their exact words as transcript and action set to whichever state "
    "fits — Taken, Refused, Delayed, Confused, or Distress — then follow the "
    "agent_hint in the tool result for your spoken reply. "
    "If they say yes, celebrate gently. If they say no, are unsure, refuse, "
    "or sound upset, stay calm and say you will let their caregiver know. "
    "Never give medical advice, change doses, or diagnose anything. "
    ""
    "If they ask what medication they're on, what time it's scheduled, or "
    "whether they've already taken it today, call query_medication_db with "
    "action='schedule' rather than guessing. If they ask how they've been "
    "doing lately, call query_medication_db with action='history'. If they "
    "ask you to add, change, or remove a medication, use manage_medications "
    "— confirm what you're about to do in one short sentence first. If they "
    "ask about side effects, dosage changes, or drug interactions, gently "
    "say that's something for their doctor or pharmacist, not you. "
    ""
    "Always reply in the same language the user just spoke. "
    "CRITICAL: Never mention that you are an AI, a model, a language model, "
    "a provider, Ollama, Qwythos, Speaches, LiveKit, Cerebras, ElevenLabs, "
    "APIs, servers, tools, or any technical system. If asked how you work, "
    "say you are ALI, a companion who helps with their health and likes to "
    "chat — nothing more."
)

ALI_GREETING = (
    "Hi {name}, it's ALI. How are you doing today?"
)


def _get_medication_status() -> list[dict]:
    req = urllib.request.Request(f"{_BACKEND_API}/api/adherence", method="GET")
    with urllib.request.urlopen(req, timeout=10.0) as resp:
        return json.loads(resp.read().decode("utf-8")).get("medications", [])


def _post_adherence_report(state: str, transcript: str, medication_id: str = "") -> dict:
    """Atomic adherence-state write — see POST /api/adherence/report.
    No re-classification round-trip: the conversational LLM already knows
    the state from context, it just needs the backend to apply it."""
    payload = {
        "state": state,
        "transcript": transcript,
        "medication_id": medication_id or None,
    }
    req = urllib.request.Request(
        f"{_BACKEND_API}/api/adherence/report",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20.0) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _get_adherence_history(days: int) -> list[dict]:
    req = urllib.request.Request(
        f"{_BACKEND_API}/api/adherence/history?days={int(days)}", method="GET"
    )
    with urllib.request.urlopen(req, timeout=10.0) as resp:
        return json.loads(resp.read().decode("utf-8")).get("days", [])


def _get_duty() -> dict:
    """The one context/state check: IDLE (companion mode) vs
    MEDICATION_ALERT (a dose is near or overdue) — see duties.py."""
    req = urllib.request.Request(f"{_BACKEND_API}/api/agent/duty", method="GET")
    with urllib.request.urlopen(req, timeout=10.0) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _post_crud(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{_BACKEND_API}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15.0) as resp:
        return json.loads(resp.read().decode("utf-8"))


_AI_INITIATED_ADDENDUM = (
    "\n\nRight now: YOU are calling THEM because it's time for a scheduled "
    "medication. Call check_duty to find out exactly which one, then lead "
    "with a warm reminder naming it specifically — don't just ask "
    "generically. This is the one situation where you bring up medication "
    "first, unprompted."
)

_PATIENT_INITIATED_ADDENDUM = (
    "\n\nRight now: THEY reached out to YOU. Open as their companion, not "
    "with a medication check-in — ask how they're doing, listen, enjoy the "
    "conversation. But remember your two duties aren't equal: medication "
    "adherence is the PRIMARY duty, and being a companion is SECONDARY — it "
    "exists to support the primary one, not replace it. So a few exchanges "
    "in (not as your opening line), call check_duty. If it comes back IDLE, "
    "stay in companion mode, no need to check again unless the "
    "conversation runs long. If it comes back MEDICATION_ALERT, the "
    "priority shifts: gently steer into it by name (\"by the way, it's "
    "about time for your...\"), rather than staying purely social for the "
    "whole call. Don't be abrupt about it; finish their thought first."
)


class ALIMedicationAgent(Agent):
    """Proactive medication-check companion for older adults."""

    def __init__(self, *, ai_initiated: bool) -> None:
        addendum = _AI_INITIATED_ADDENDUM if ai_initiated else _PATIENT_INITIATED_ADDENDUM
        super().__init__(instructions=ALI_INSTRUCTIONS + addendum)

    async def _report(self, state: str, transcript: str, medication_id: str) -> str:
        """Shared implementation behind every atomic report_* tool below."""
        try:
            data = await asyncio.to_thread(_post_adherence_report, state, transcript, medication_id)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
            logger.warning("adherence report failed: %s", exc)
            return (
                "Report unavailable. Respond gently and continue the medication "
                "check-in without mentioning technical problems."
            )

        applied = data.get("applied") or {}
        hint = applied.get("agent_hint") or ""
        logger.info(
            "adherence.report state=%s action=%s duplicate=%s",
            state, applied.get("action"), applied.get("duplicate"),
        )
        return (
            f"state={state}; action={applied.get('action')}; "
            f"duplicate={applied.get('duplicate')}; agent_hint={hint}"
        )

    @function_tool(
        description=(
            "Record the patient's medication adherence response — one atomic "
            "tool for every state. `action` must be exactly one of: "
            "'Taken' (they confirmed taking it — celebrate gently), "
            "'Refused' (they declined — stay calm, don't argue), "
            "'Delayed' (they'll take it later, not now), "
            "'Confused' (unsure which pill or what to do), "
            "'Distress' (scared, in pain, or describing an emergency — HIGH "
            "PRIORITY, alerts their caregiver immediately). "
            "Call this once per medication-related answer, with their exact "
            "words as transcript."
        )
    )
    async def report_medication_status(
        self, context: RunContext, action: str, transcript: str, medication_id: str = ""
    ) -> str:
        """Single atomic write tool — `action` selects which adherence state
        to record, instead of one tool per state."""
        return await self._report(action.strip().capitalize(), transcript, medication_id)

    @function_tool(
        description=(
            "Look up medication information from the database — one atomic "
            "tool for every lookup. `action` must be exactly one of: "
            "'schedule' (today's medications, scheduled times, and whether "
            "each has been taken — use for 'what pill do I take' / 'have I "
            "taken it yet' questions) or 'history' (adherence over the last "
            "several days — use for 'how have I been doing lately' "
            "questions). Do not use this for medical advice (side effects, "
            "dosage changes, drug interactions) — that's out of scope; tell "
            "them to ask their doctor or pharmacist instead."
        )
    )
    async def query_medication_db(self, context: RunContext, action: str, days: int = 7) -> str:
        """Single atomic read tool — `action` selects schedule vs history,
        instead of one tool per query type."""
        action = action.strip().lower()

        if action == "history":
            try:
                history = await asyncio.to_thread(_get_adherence_history, days)
            except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
                logger.warning("adherence history lookup failed: %s", exc)
                return "History unavailable — apologize briefly and continue the check-in."
            if not history:
                return "No adherence history available yet."
            lines = [
                f"{day['date']} — " + ", ".join(f"{m['name']}: {m['status']}" for m in day.get("medications", []))
                for day in history
            ]
            return "Recent history — " + "; ".join(lines)

        # action == "schedule" (default fallback for any other value)
        try:
            meds = await asyncio.to_thread(_get_medication_status)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
            logger.warning("medication status lookup failed: %s", exc)
            return "Schedule lookup unavailable — apologize briefly and continue the check-in."
        if not meds:
            return "No medications are currently scheduled."
        lines = []
        for m in meds:
            if m["status"] == "taken":
                detail = f"already taken today at {m['taken_at']}"
            elif m["status"] == "missed":
                detail = f"was scheduled for {m['time']} and was missed today"
            else:
                detail = f"scheduled for {m['time']}, not yet taken"
            lines.append(f"{m['name']}: {detail}")
        return "Today's schedule — " + "; ".join(lines)

    @function_tool(
        description=(
            "Look up exactly which medication is due and how soon. Returns "
            "IDLE (nothing due) or MEDICATION_ALERT (a dose is near or "
            "overdue, with its name and time). Whether and when to call "
            "this depends on who started the call — see your system "
            "instructions for which situation you're in right now."
        )
    )
    async def check_duty(self, context: RunContext) -> str:
        """The one context/state-loop tool — see duties.py."""
        try:
            duty = await asyncio.to_thread(_get_duty)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
            logger.warning("duty check failed: %s", exc)
            return "Duty check unavailable — default to being a warm companion."
        if duty.get("duty") == "MEDICATION_ALERT":
            med = duty.get("medication") or {}
            return (
                f"MEDICATION_ALERT: {med.get('name')} was scheduled for {med.get('time')} "
                f"(status={med.get('status')}, minutes_until={duty.get('minutes_until')}). "
                f"Gently bring this up."
            )
        return "IDLE: nothing due soon. Be a companion — ask about their day, chat naturally."

    @function_tool(
        description=(
            "Manage the patient's medication list — one atomic tool for "
            "every CRUD action. `action` must be exactly one of: "
            "'create' (add a new medication — needs name and time), "
            "'read' (list all scheduled medications), "
            "'update' (change an existing one's name or time — needs "
            "medication_id), 'delete' (remove one — needs medication_id). "
            "Only do this when the patient explicitly asks to add, change, "
            "or remove a medication — never on your own initiative."
        )
    )
    async def manage_medications(
        self,
        context: RunContext,
        action: str,
        medication_id: str = "",
        name: str = "",
        time: str = "",
    ) -> str:
        """CRUD for reminders.medications — see medications_crud.py."""
        try:
            data = await asyncio.to_thread(
                _post_crud,
                "/api/medications/crud",
                {"action": action.strip().lower(), "medication_id": medication_id, "name": name, "time": time},
            )
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
            logger.warning("medication crud failed: %s", exc)
            return "That didn't go through — apologize briefly and offer to try again."
        return f"result={data.get('result')}"

    @function_tool(
        description=(
            "Manage your own persistent notes about this patient — things "
            "worth remembering for next time (preferences, what they "
            "mentioned, how they're doing). One atomic tool for every CRUD "
            "action. `action` must be exactly one of: 'create' (write a new "
            "markdown note — needs title and content_markdown), 'read' (get "
            "one note by note_id, or list all notes if note_id is empty), "
            "'update' (revise an existing note — needs note_id), 'delete' "
            "(remove a note — needs note_id). Use this naturally during "
            "companion conversation to remember what matters to them."
        )
    )
    async def manage_notes(
        self,
        context: RunContext,
        action: str,
        note_id: str = "",
        title: str = "",
        content_markdown: str = "",
    ) -> str:
        """CRUD for ALI's own markdown memory — see notes.py."""
        try:
            data = await asyncio.to_thread(
                _post_crud,
                "/api/notes/crud",
                {"action": action.strip().lower(), "note_id": note_id, "title": title, "content_markdown": content_markdown},
            )
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
            logger.warning("notes crud failed: %s", exc)
            return "Couldn't save that note — apologize briefly and continue naturally."
        return f"result={data.get('result')}"


def _log_pipeline_latency(ev: MetricsCollectedEvent) -> None:
    """Log STT/LLM/TTS timings and a rough e2e estimate (report L_total)."""
    metrics.log_metrics(ev.metrics)

    stt_ms = llm_ttft_ms = tts_ttfb_ms = eou_ms = None
    m = ev.metrics
    mtype = getattr(m, "type", None)

    if mtype == "eou_metrics":
        eou_ms = (m.end_of_utterance_delay + m.transcription_delay) * 1000
        logger.info(
            "latency.eou_ms=%.0f (eou_delay=%.0f transcription=%.0f)",
            eou_ms,
            m.end_of_utterance_delay * 1000,
            m.transcription_delay * 1000,
        )
    elif mtype == "llm_metrics":
        llm_ttft_ms = m.ttft * 1000
        logger.info("latency.llm_ttft_ms=%.0f duration_ms=%.0f", llm_ttft_ms, m.duration * 1000)
    elif mtype == "tts_metrics":
        tts_ttfb_ms = m.ttfb * 1000
        logger.info("latency.tts_ttfb_ms=%.0f audio_ms=%.0f", tts_ttfb_ms, m.audio_duration * 1000)
    elif mtype == "stt_metrics":
        stt_ms = m.duration * 1000
        logger.info("latency.stt_ms=%.0f audio_ms=%.0f", stt_ms, m.audio_duration * 1000)

    speech_id = getattr(m, "speech_id", None) or "_"
    bucket = _latency_buckets.setdefault(speech_id, {})
    if eou_ms is not None:
        bucket["eou_ms"] = eou_ms
    if llm_ttft_ms is not None:
        bucket["llm_ttft_ms"] = llm_ttft_ms
    if tts_ttfb_ms is not None:
        bucket["tts_ttfb_ms"] = tts_ttfb_ms
    if stt_ms is not None:
        bucket["stt_ms"] = stt_ms

    if {"eou_ms", "llm_ttft_ms", "tts_ttfb_ms"} <= bucket.keys():
        total = bucket["eou_ms"] + bucket["llm_ttft_ms"] + bucket["tts_ttfb_ms"]
        over = total > _LATENCY_BUDGET_MS
        logger.info(
            "latency.e2e_ms=%.0f budget_ms=%.0f over_budget=%s speech_id=%s parts=%s",
            total,
            _LATENCY_BUDGET_MS,
            over,
            speech_id,
            bucket,
        )
        _latency_buckets.pop(speech_id, None)


_latency_buckets: dict[str, dict[str, float]] = {}


_JOIN_TIMEOUT_SECONDS = 600.0


async def _wait_for_patient(ctx: JobContext) -> bool:
    """Block until a real (non-agent) participant is in the room."""
    if ctx.room.remote_participants:
        return True

    joined = asyncio.Event()

    def _on_joined(_participant) -> None:
        joined.set()

    ctx.room.on("participant_connected", _on_joined)
    try:
        await asyncio.wait_for(joined.wait(), timeout=_JOIN_TIMEOUT_SECONDS)
        return True
    except asyncio.TimeoutError:
        logger.info(
            "No participant joined room=%s within %.0fs — giving up",
            ctx.room.name,
            _JOIN_TIMEOUT_SECONDS,
        )
        return False
    finally:
        ctx.room.off("participant_connected", _on_joined)


_SILENCE_NUDGE_SECONDS = 20.0

# After this many unanswered nudges (~2 minutes of dead air), stop trying —
# nobody is there. Alert the caregiver and end the call instead of nudging
# into an empty room indefinitely.
_MAX_SILENCE_NUDGES = 6

NUDGE_INSTRUCTIONS_TEMPLATE = (
    "The person hasn't said anything since you last spoke. Say hello to "
    "{name} again by name and gently remind them it's time for their "
    "medication, in one short warm sentence. Use different wording than "
    "your previous attempts — don't repeat yourself verbatim. Do not "
    "mention silence, timeouts, or technology."
)


class SilenceWatchdog:
    """Speaks again if the patient goes quiet after the agent's turn.

    Keyed off agent/user state transitions rather than a fixed poll: a timer
    starts the moment the agent finishes speaking and is waiting on the
    patient (agent state -> "listening"); it's cancelled the instant the
    patient starts speaking. If it fires uninterrupted, the agent nudges
    again — with different phrasing each time (the LLM is instructed not to
    repeat itself) — every _SILENCE_NUDGE_SECONDS.

    After _MAX_SILENCE_NUDGES unanswered attempts, it gives up: nobody is
    there. Rather than nudging into an empty room forever, it calls
    `on_give_up` once (alerts the caregiver and ends the call — see
    entrypoint()) and stops rescheduling.
    """

    def __init__(self, session: AgentSession, patient_name: str, on_give_up) -> None:
        self._session = session
        self._patient_name = patient_name
        self._on_give_up = on_give_up
        self._task: asyncio.Task[None] | None = None
        self._nudge_count = 0
        self._given_up = False

    def _cancel(self) -> None:
        if self._task is not None and not self._task.done():
            self._task.cancel()
        self._task = None

    def _schedule(self) -> None:
        if self._given_up:
            return
        self._cancel()
        self._task = asyncio.create_task(self._wait_then_nudge())

    async def _wait_then_nudge(self) -> None:
        try:
            await asyncio.sleep(_SILENCE_NUDGE_SECONDS)
        except asyncio.CancelledError:
            return

        if self._nudge_count >= _MAX_SILENCE_NUDGES:
            self._given_up = True
            logger.info(
                "No response from patient after %d nudges (~%.0fs) — giving up",
                self._nudge_count,
                self._nudge_count * _SILENCE_NUDGE_SECONDS,
            )
            await self._on_give_up()
            return

        self._nudge_count += 1
        logger.info(
            "No response from patient for %.0fs — nudging (attempt %d/%d)",
            _SILENCE_NUDGE_SECONDS,
            self._nudge_count,
            _MAX_SILENCE_NUDGES,
        )
        # user_input only (no instructions=) — see the comment on the
        # greeting's session.say() call: passing instructions here would
        # append a second system message after existing conversation
        # history, which the local model's chat template rejects once any
        # user/assistant turns already exist.
        instructions = NUDGE_INSTRUCTIONS_TEMPLATE.format(name=self._patient_name)
        self._session.generate_reply(
            user_input=f"(Stage direction, do not say this aloud: {instructions})"
        )

    def on_agent_state_changed(self, ev: AgentStateChangedEvent) -> None:
        if self._given_up:
            return
        if ev.new_state == "listening":
            self._schedule()
        else:
            self._cancel()

    def on_user_state_changed(self, ev: UserStateChangedEvent) -> None:
        if ev.new_state == "speaking":
            self._nudge_count = 0  # they responded — the watchdog resets
            self._cancel()


def _get_greeting_context(ctx: JobContext) -> str:
    """Which greeting template to use — read from the LiveKit job dispatch's
    metadata (see livekit_service.dispatch_agent), not an env var: the
    backend that dispatches this job is a separate OS process from this
    agent worker, so an env var set in the backend at dispatch time would
    never actually reach this process."""
    try:
        data = json.loads(ctx.job.metadata or "{}")
    except (json.JSONDecodeError, TypeError):
        data = {}
    return data.get("greeting_context") or "reminder_call"


_GENERIC_PARTICIPANT_NAMES = {"", "user", "doseluma", "patient", "guest"}


def _resolve_patient_name(ctx: JobContext) -> str:
    """Read the connecting participant's display name off the room.

    The frontend sends this as `user_name` to POST /api/livekit/connect,
    which embeds it as the `name` claim on the LiveKit token (see
    livekit_service.generate_access_token) — so by the time we're here,
    ctx.room.remote_participants carries the patient's real name. Falls
    back to "there" for placeholder/blank names so the greeting still
    reads naturally ("Hi there, ...").
    """
    for participant in ctx.room.remote_participants.values():
        name = (participant.name or "").strip()
        if name and name.lower() not in _GENERIC_PARTICIPANT_NAMES:
            return name
    return "there"


async def _give_up_on_silence(ctx: JobContext, session: AgentSession) -> None:
    """SilenceWatchdog's give-up path: nobody answered after repeated
    nudges. Alert the caregiver (reusing the same adherence-report pipeline
    the LLM's own report_medication_status tool uses — see NoResponse in
    intent.py/adherence.py) and end the call rather than keep running with
    no one there."""
    try:
        await asyncio.to_thread(
            _post_adherence_report, "NoResponse", "No response after repeated nudges."
        )
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
        logger.warning("failed to post NoResponse alert: %s", exc)

    try:
        await session.aclose()
    except Exception:
        logger.exception("error closing session after silence give-up")

    ctx.shutdown(reason="no_response_timeout")


def _select_greeting_template(context: str, name: str) -> str:
    """Select a random greeting template for `context`, with `{name}` filled in."""
    import random

    agent_cfg = config.get_agent_config()
    templates = agent_cfg.get("greeting_templates", {})

    if context in templates and templates[context]:
        template = random.choice(templates[context])
    else:
        template = ALI_GREETING
    return template.replace("{name}", name)


async def entrypoint(ctx: JobContext) -> None:
    started = time.perf_counter()
    logger.info("Voice agent joining room: %s", ctx.room.name)

    await ctx.connect()

    session = AgentSession(
        vad=config.build_vad(),
        stt=config.build_stt(),
        llm=config.build_llm(),
        # ElevenLabs pacing comes from config.json's tts.speed (voice_settings),
        # not this function argument — see config.build_tts()'s elevenlabs branch.
        tts=config.build_tts(),
    )

    @session.on("metrics_collected")
    def _on_metrics(ev: MetricsCollectedEvent) -> None:
        _log_pipeline_latency(ev)

    # Read before session.start() (not after) — the persona itself differs
    # depending on who initiated the call (see ALIMedicationAgent), and
    # job.metadata is available immediately, no need to wait for the patient.
    greeting_context = _get_greeting_context(ctx)
    ai_initiated = greeting_context == "reminder_call"

    await session.start(room=ctx.room, agent=ALIMedicationAgent(ai_initiated=ai_initiated))

    if not await _wait_for_patient(ctx):
        return

    agent_cfg = config.get_agent_config()
    should_greet = agent_cfg.get("greet_on_start", True)
    patient_name = _resolve_patient_name(ctx)

    # Constructed here (not earlier) since the watchdog's repeated nudges
    # need the patient's name, which isn't known until they've joined.
    watchdog = SilenceWatchdog(
        session, patient_name, on_give_up=lambda: _give_up_on_silence(ctx, session)
    )
    session.on("agent_state_changed", watchdog.on_agent_state_changed)
    session.on("user_state_changed", watchdog.on_user_state_changed)

    if should_greet:
        greeting_text = _select_greeting_template(greeting_context, patient_name)
        # Speak the canned greeting directly via TTS instead of routing it
        # through generate_reply(instructions=...): that call appends a
        # second system message *after* the synthetic user turn, and the
        # local Ollama model's chat template rejects any chat context where
        # a system message isn't first ("System message must be at the
        # beginning"). say() goes straight to TTS and still records the
        # greeting as an assistant turn, so follow-up replies see it as
        # conversation history.
        session.say(greeting_text, add_to_chat_ctx=True)
    logger.info(
        "Agent ready in room=%s setup_ms=%.0f greet=%s context=%s",
        ctx.room.name,
        (time.perf_counter() - started) * 1000,
        should_greet,
        greeting_context,
    )


if __name__ == "__main__":
    cli.run_app(
        WorkerOptions(
            entrypoint_fnc=entrypoint,
            agent_name=config.agent_name(),
        )
    )
