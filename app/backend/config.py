"""
Unified model/provider configuration.

Repo-root `config.json` is the single source of truth for which providers and
models the app uses (STT / single LLM / bilingual TTS routing / VAD / agent).
Nothing else should hard-code a model name, voice id, or agent name — it all
comes from there.

`services.llm` is OpenAI-compatible and provider-agnostic (ollama, lmstudio,
or any other local `/v1` server). Swap by changing `provider` + `base_url`.

Secrets (API keys, LiveKit URL/key/secret) intentionally stay in environment
variables and are NOT stored in config.json.
"""

from __future__ import annotations

import functools
import json
import os
from pathlib import Path

# Prefer an explicit override so external agents (e.g. ~/repos/livekit-agent)
# can point at this repo's root config without hard-coding paths.
# config.py lives at app/backend/config.py → repo root is parents[2].
_DEFAULT_CONFIG = Path(__file__).resolve().parents[2] / "config.json"
CONFIG_PATH = Path(os.getenv("MODEL_CONFIG_PATH", str(_DEFAULT_CONFIG))).expanduser()

# Local OpenAI-compatible LLM backends — all speak the same /v1 chat API.
_LOCAL_LLM_PROVIDERS = frozenset({"ollama", "lmstudio", "openai_compatible"})


@functools.lru_cache(maxsize=1)
def load_config() -> dict:
    """Load and cache config.json."""
    with CONFIG_PATH.open("r", encoding="utf-8") as f:
        return json.load(f)


def _section(name: str) -> dict:
    cfg = load_config()
    if name not in cfg:
        raise KeyError(f"config.json is missing the '{name}' section")
    return cfg[name]


# ---- Non-secret accessors -------------------------------------------------

def agent_name() -> str:
    return _section("agent")["name"]


def default_room() -> str:
    return _section("agent").get("room", "")


def get_agent_config() -> dict:
    return _section("agent")


def llm_service() -> dict:
    return _section("services")["llm"]


def speech_service() -> dict:
    return _section("services")["speech"]


def llm_provider() -> str:
    return llm_service()["provider"]


def llm_base_url() -> str:
    return llm_service()["base_url"]


def speech_provider() -> str:
    return speech_service()["provider"]


def speech_base_url() -> str:
    return speech_service()["base_url"]


def stt_model() -> str:
    return _section("stt")["model"]


def stt_detect_language() -> bool:
    return bool(_section("stt").get("detect_language", True))


def llm_model() -> str:
    return _section("llm")["model"]


def llm_fallback_contains() -> str:
    return _section("llm").get("fallback_contains", "Qwythos")


def llm_api_key() -> str:
    """The bearer token for whichever LLM provider is configured — used by
    raw HTTP callers (intent.py's classify_llm) that don't go through
    build_llm()'s livekit Plugin wrapper. Local providers (Ollama/LM
    Studio) don't check auth at all, hence the placeholder."""
    provider = llm_provider()
    if provider == "openrouter":
        key = os.getenv("OPENROUTER_API_KEY")
    elif provider == "cerebras":
        key = os.getenv("CEREBRAS_API_KEY")
    else:
        return os.getenv("LLM_API_KEY", "not-needed")
    if not key:
        raise ValueError(f"API key environment variable not set for llm provider {provider!r}")
    return key


def tts_route(lang: str) -> dict:
    routing = _section("tts").get("routing") or {}
    if lang not in routing:
        raise KeyError(f"config.json tts.routing is missing '{lang}'")
    return routing[lang]


# ---- Provider factories ---------------------------------------------------
# livekit plugins are imported lazily so the web server can import this module
# without pulling in the heavy agent/ML dependencies.

def build_llm():
    provider = llm_provider()
    if provider in _LOCAL_LLM_PROVIDERS:
        from livekit.plugins.openai import LLM as OpenAICompatLLM

        # Generic OpenAI-compatible client — works for Ollama, LM Studio, etc.
        return OpenAICompatLLM(
            model=llm_model(),
            base_url=llm_base_url(),
            api_key=os.getenv("LLM_API_KEY", "not-needed"),
        )
    if provider == "openrouter":
        from livekit.plugins.openai import LLM as OpenAICompatLLM

        api_key = os.getenv("OPENROUTER_API_KEY")
        if not api_key:
            raise ValueError("OPENROUTER_API_KEY environment variable not set")
        return OpenAICompatLLM(
            model=llm_model(),
            base_url=llm_service().get("base_url", "https://openrouter.ai/api/v1"),
            api_key=api_key,
        )
    if provider == "cerebras":
        from livekit.plugins.openai import LLM as OpenAICompatLLM

        # Cerebras Cloud — OpenAI-compatible endpoint, wafer-scale inference
        # hardware gives dramatically lower LLM latency than the local
        # Cloud inference is available when the local path cannot meet the
        # configured latency budget; see benchmark/latency.py.
        api_key = os.getenv("CEREBRAS_API_KEY")
        if not api_key:
            raise ValueError("CEREBRAS_API_KEY environment variable not set")
        return OpenAICompatLLM(
            model=llm_model(),
            base_url=llm_service().get("base_url", "https://api.cerebras.ai/v1"),
            api_key=api_key,
        )
    raise ValueError(f"Unsupported llm provider: {provider!r}")


def build_stt():
    cfg = _section("stt")
    provider = cfg["provider"]
    if provider == "speaches":
        from livekit.plugins import openai

        return openai.STT(
            model=cfg["model"],
            base_url=speech_base_url(),
            api_key="not-needed",
            detect_language=cfg.get("detect_language", True),
        )
    if provider == "elevenlabs":
        from livekit.plugins import elevenlabs

        api_key = os.getenv("ELEVEN_API_KEY")
        if not api_key:
            raise ValueError("ELEVEN_API_KEY environment variable not set")
        return elevenlabs.STT(api_key=api_key, model_id=cfg.get("model_id", "scribe_v1"))
    raise ValueError(f"Unsupported stt provider: {provider!r}")


def build_tts(*, speed: float = 1.0):
    cfg = _section("tts")
    provider = cfg["provider"]
    if provider == "speaches":
        from livekit.plugins import openai

        # Default session TTS is the English route; bilingual routing is handled
        # by the external livekit-agent BilingualTTS wrapper.
        route = tts_route("en") if "routing" in cfg else cfg
        model = route["model"]
        voice = route["voice"]
        openai.tts.AUDIO_STREAM_MODELS.add(model)
        return openai.TTS(
            model=model,
            voice=voice,
            speed=speed,
            base_url=speech_base_url(),
            api_key="not-needed",
        )
    if provider == "elevenlabs":
        from livekit.plugins import elevenlabs

        # ElevenLabs' speed control lives in voice_settings, not a top-level
        # `speed=` kwarg like Kokoro's — the `speed` function argument is
        # ignored here and config.json's tts.speed is used instead (valid
        # range ~0.7-1.2; lower = slower, tuned for elderly listeners).
        api_key = os.getenv("ELEVEN_API_KEY")
        if not api_key:
            raise ValueError("ELEVEN_API_KEY environment variable not set")
        voice_settings = elevenlabs.VoiceSettings(
            stability=cfg.get("stability", 0.5),
            similarity_boost=cfg.get("similarity_boost", 0.75),
            speed=cfg.get("speed", 1.0),
        )
        return elevenlabs.TTS(
            voice_id=cfg["voice_id"],
            model=cfg.get("model", "eleven_turbo_v2_5"),
            voice_settings=voice_settings,
            api_key=api_key,
        )
    raise ValueError(f"Unsupported tts provider: {provider!r}")


def build_vad():
    """Build VAD tuned for older-adult speech patterns.

    Slower speech rate and longer natural pauses mean the
    stock defaults are prone to cutting a patient off mid-sentence. Values
    come from config.json's vad section so they can be tuned without a
    code change; falls back to the library defaults if unset."""
    cfg = _section("vad")
    provider = cfg["provider"]
    if provider == "silero":
        from livekit.plugins import silero

        return silero.VAD.load(
            min_silence_duration=cfg.get("min_silence_duration", 0.55),
            activation_threshold=cfg.get("activation_threshold", 0.5),
            prefix_padding_duration=cfg.get("prefix_padding_duration", 0.5),
        )
    raise ValueError(f"Unsupported vad provider: {provider!r}")
