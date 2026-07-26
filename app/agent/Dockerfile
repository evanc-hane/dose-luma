FROM python:3.11-slim

WORKDIR /app

# Install uv
RUN pip install uv

# Reuse the backend Python project (shared deps + config.py)
COPY backend/pyproject.toml backend/uv.lock ./
RUN uv sync --no-dev

COPY backend/config.py ./
COPY agent/voice_agent.py ./

# Root config.json is mounted at runtime (see docker-compose)
ENV MODEL_CONFIG_PATH=/config/config.json
ENV PYTHONPATH=/app

CMD ["uv", "run", "python", "voice_agent.py", "dev"]
