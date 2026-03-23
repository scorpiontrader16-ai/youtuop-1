"""
ML Engine — FastAPI application
Model serving + Feature Store + Prediction logging
"""
from __future__ import annotations

import asyncio
import logging
import os
from contextlib import asynccontextmanager

import asyncpg
import redis.asyncio as aioredis
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, make_asgi_app

from app.config import get_settings
from app.api.inference import router as inference_router
from app.models.registry import ModelRegistry
from app.features.store import FeatureStore

logger = logging.getLogger(__name__)

# ── Prometheus metrics ────────────────────────────────────────────────────
PREDICTION_COUNTER = Counter(
    "ml_engine_predictions_total",
    "Total predictions served",
    ["model_type", "status"],
)
PREDICTION_LATENCY = Histogram(
    "ml_engine_prediction_latency_seconds",
    "Prediction latency",
    ["model_type"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0],
)
MODELS_LOADED = Counter(
    "ml_engine_models_loaded_total",
    "Total models loaded",
    ["model_type", "framework"],
)


# ── Lifespan ──────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup + shutdown lifecycle"""
    settings = get_settings()
    logger.info("ml-engine starting", extra={"version": settings.version})

    # ── Redis ──────────────────────────────────────────────────────────────
    redis_client = aioredis.from_url(
        f"redis://{settings.redis_addr}",
        password=settings.redis_password or None,
        decode_responses=True,
    )
    await redis_client.ping()
    logger.info("redis connected")

    # ── Postgres ───────────────────────────────────────────────────────────
    pg_pool = await asyncpg.create_pool(
        dsn=(
            f"postgresql://{settings.postgres_user}:{settings.postgres_password}"
            f"@{settings.postgres_host}:{settings.postgres_port}/{settings.postgres_db}"
        ),
        min_size=2,
        max_size=5,
    )
    logger.info("postgres connected")

    # ── Load production models ─────────────────────────────────────────────
    registry = ModelRegistry(
        bucket=settings.model_artifacts_bucket,
        aws_region=settings.aws_region,
    )

    async with pg_pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT id, name, version, type, framework,
                   artifact_path, input_schema, output_schema, metrics
            FROM ml_models
            WHERE status = 'production' AND is_default = TRUE
        """)
        db_models = [dict(r) for r in rows]

    if db_models:
        await registry.load_production_models(db_models)
        for m in db_models:
            MODELS_LOADED.labels(
                model_type=m["type"],
                framework=m["framework"],
            ).inc()
        logger.info(f"loaded {len(db_models)} production models")
    else:
        logger.warning("no production models found in DB — running without models")

    # ── Feature Store ──────────────────────────────────────────────────────
    feature_store = FeatureStore(
        redis_client=redis_client,
        default_ttl=settings.feature_cache_ttl,
    )

    app.state.registry = registry
    app.state.feature_store = feature_store
    app.state.pg_pool = pg_pool
    app.state.redis = redis_client

    logger.info("ml-engine ready")
    yield

    # ── Shutdown ───────────────────────────────────────────────────────────
    await pg_pool.close()
    await redis_client.aclose()
    logger.info("ml-engine shutdown complete")


# ── App ───────────────────────────────────────────────────────────────────

settings = get_settings()

app = FastAPI(
    title="youtuop ML Engine",
    description="AI/ML inference service — model serving + feature store",
    version=settings.version,
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://app.youtuop-1.com", "https://developers.youtuop-1.com"],
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type", "x-tenant-id", "x-user-id"],
)

app.include_router(inference_router)

metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/readyz")
async def readyz():
    """يتحقق من الـ Redis + Postgres + loaded models"""
    # FIX: كان بيرجع tuple (dict, int) — FastAPI مش بيعرفها
    # الصح هو JSONResponse مع status_code صريح
    try:
        await app.state.redis.ping()
    except Exception as e:
        return JSONResponse(
            status_code=503,
            content={"status": "degraded", "reason": f"redis: {e}"},
        )

    try:
        async with app.state.pg_pool.acquire() as conn:
            await conn.fetchval("SELECT 1")
    except Exception as e:
        return JSONResponse(
            status_code=503,
            content={"status": "degraded", "reason": f"postgres: {e}"},
        )

    loaded = app.state.registry.list_loaded()
    return JSONResponse(
        status_code=200,
        content={
            "status": "ready",
            "models_loaded": len(loaded),
            "model_types": loaded,
        },
    )
