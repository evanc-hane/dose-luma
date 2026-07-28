FROM python:3.11-slim

WORKDIR /app

# Pin uv, then reuse the backend project with the voice-agent extra.
RUN pip install --no-cache-dir uv==0.11.33
COPY backend/pyproject.toml backend/uv.lock ./
RUN uv sync --locked --no-dev --extra agent

COPY backend/config.py ./
COPY agent/voice_agent.py ./

# Root config.json is mounted at runtime (see docker-compose)
ENV MODEL_CONFIG_PATH=/config/config.json
ENV PYTHONPATH=/app

CMD ["uv", "run", "python", "voice_agent.py", "dev"]
