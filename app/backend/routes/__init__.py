"""API route modules, grouped by concern instead of one flat index.py.

- livekit.py   — how the frontend (iOS phone, mac, web) gets a room token
                  and gets the agent dispatched into the room.
- state.py     — the /ws/state push channel + the broadcast helper the
                  adherence routes call after every mutation.
- adherence.py — adherence status, caregiver alerts, intent classification.
- greetings.py — voice agent greeting templates.
- reminders.py — medication reminder schedule (Expo local notifications).
- auth.py      — name-based account register/refresh for the DoseLuma Swift
                  app (no passwords — see users.py).
- user.py      — logged-in user's own profile + push token.
- links.py     — caregiver's patient roster + per-patient adherence/meds
                  (every patient account is visible to every caregiver —
                  see links.py's docstring).
- mobile.py    — DoseLuma Swift app's background sync + pill-scan logging
                  (see mobile_sync.py for why sync only ever echoes back
                  what it's given).

Each module exports a `router: APIRouter`; index.py wires them onto the app.
"""
