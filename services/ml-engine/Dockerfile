FROM --platform=$BUILDPLATFORM python:3.12-slim AS builder
ARG TARGETARCH=arm64
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN python -m venv /app/.venv && \
    /app/.venv/bin/pip install --no-cache-dir --upgrade pip && \
    /app/.venv/bin/pip install --no-cache-dir -r requirements.txt

# ── Runtime ───────────────────────────────────────────────────────────────
# لماذا python:3.12-slim وليس distroless:
# torch 2.6.0 + lightgbm يحتاجان libgomp1 وPython 3.12
# gcr.io/distroless/python3 يوفر Python 3.11 فقط — غير متوافق
FROM python:3.12-slim AS runtime
ARG BUILD_VERSION=dev

# فقط runtime libs — بدون gcc/build tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get purge -y --auto-remove

RUN groupadd -r -g 65532 appuser && useradd -r -u 65532 -g appuser appuser
WORKDIR /app

COPY --from=builder --chown=appuser:appuser /app/.venv /app/.venv
ENV PATH=/app/.venv/bin:$PATH
COPY --chown=appuser:appuser . .

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV VERSION=${BUILD_VERSION}

LABEL org.opencontainers.image.title="ml-engine"
LABEL org.opencontainers.image.description="Python ML inference engine — model serving + feature store"

USER 65532:65532
EXPOSE 9098
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "9098", "--workers", "2"]
