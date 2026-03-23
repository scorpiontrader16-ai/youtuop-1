"""
Inference API — الـ endpoints اللي بتعمل predictions
"""
from __future__ import annotations

import logging
import time
import uuid
from typing import Any, Dict, List, Optional

import numpy as np
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from app.config import get_settings
from app.models.registry import ModelRegistry
from app.features.store import FeatureStore

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/v1/ml", tags=["inference"])


# ── Request / Response Models ─────────────────────────────────────────────

class PredictRequest(BaseModel):
    entity_id: str = Field(..., description="Symbol أو asset identifier")
    model_type: str = Field(..., description="نوع الـ model المطلوب")
    features: Optional[Dict[str, Any]] = Field(
        None, description="Features مباشرة — لو مش موجودة هيجيبها من الـ feature store"
    )
    use_cache: bool = Field(True, description="هل نستخدم الـ feature cache؟")


class PredictResponse(BaseModel):
    request_id: str
    entity_id: str
    model_type: str
    model_version: str
    prediction: Dict[str, Any]
    confidence: Optional[float]
    latency_ms: int
    features_used: int


class BatchPredictRequest(BaseModel):
    requests: List[PredictRequest]


class BatchPredictResponse(BaseModel):
    results: List[PredictResponse]
    total_latency_ms: int
    failed_count: int


class ModelInfo(BaseModel):
    type: str
    name: str
    version: str
    framework: str
    status: str


# ── Dependency injection ──────────────────────────────────────────────────

def get_registry(request: Request) -> ModelRegistry:
    return request.app.state.registry


def get_feature_store(request: Request) -> FeatureStore:
    return request.app.state.feature_store


# ── Endpoints ─────────────────────────────────────────────────────────────

@router.post("/predict", response_model=PredictResponse)
async def predict(
    req: PredictRequest,
    registry: ModelRegistry = Depends(get_registry),
    feature_store: FeatureStore = Depends(get_feature_store),
) -> PredictResponse:
    """
    Single prediction endpoint
    """
    start = time.monotonic()
    request_id = str(uuid.uuid4())

    # 1. Load model
    loaded = registry.get(req.model_type)
    if loaded is None:
        raise HTTPException(
            status_code=503,
            detail=f"Model '{req.model_type}' not available. Loaded: {registry.list_loaded()}",
        )

    # 2. Get features
    features = req.features or {}
    if req.use_cache and not features:
        feature_names = list(loaded.input_schema.get("features", []))
        if feature_names:
            cached = await feature_store.get_features(req.entity_id, feature_names)
            features = {k: v for k, v in cached.items() if v is not None}

    if not features:
        raise HTTPException(
            status_code=422,
            detail="No features provided and no cached features found for entity",
        )

    # 3. Run inference
    prediction, confidence = _run_inference(loaded, features)

    latency_ms = int((time.monotonic() - start) * 1000)

    logger.info(
        "prediction complete",
        extra={
            "request_id": request_id,
            "model_type": req.model_type,
            "entity_id": req.entity_id,
            "latency_ms": latency_ms,
        },
    )

    return PredictResponse(
        request_id=request_id,
        entity_id=req.entity_id,
        model_type=req.model_type,
        model_version=loaded.version,
        prediction=prediction,
        confidence=confidence,
        latency_ms=latency_ms,
        features_used=len(features),
    )


@router.post("/predict/batch", response_model=BatchPredictResponse)
async def predict_batch(
    req: BatchPredictRequest,
    registry: ModelRegistry = Depends(get_registry),
    feature_store: FeatureStore = Depends(get_feature_store),
) -> BatchPredictResponse:
    """
    Batch prediction — up to 64 requests
    """
    settings = get_settings()
    if len(req.requests) > settings.max_batch_size:
        raise HTTPException(
            status_code=422,
            detail=f"Batch size {len(req.requests)} exceeds limit {settings.max_batch_size}",
        )

    start = time.monotonic()
    results = []
    failed = 0

    for single_req in req.requests:
        try:
            result = await predict(single_req, registry, feature_store)
            results.append(result)
        except HTTPException as e:
            failed += 1
            logger.warning(
                "batch item failed",
                extra={"entity_id": single_req.entity_id, "error": e.detail},
            )

    total_latency_ms = int((time.monotonic() - start) * 1000)

    return BatchPredictResponse(
        results=results,
        total_latency_ms=total_latency_ms,
        failed_count=failed,
    )


@router.get("/models", response_model=List[str])
async def list_models(registry: ModelRegistry = Depends(get_registry)) -> List[str]:
    """يجيب قائمة الـ models المحملة حالياً"""
    return registry.list_loaded()


@router.post("/features/{entity_id}")
async def upsert_features(
    entity_id: str,
    features: Dict[str, Any],
    ttl: int = 300,
    feature_store: FeatureStore = Depends(get_feature_store),
) -> Dict[str, str]:
    """
    Internal endpoint — بيُستدعى من الـ processing service
    لحفظ الـ computed features في الـ feature store
    """
    await feature_store.set_features(entity_id, features, ttl)
    return {"status": "ok", "entity_id": entity_id, "features_stored": str(len(features))}


@router.get("/features/{entity_id}")
async def get_features(
    entity_id: str,
    names: str = "",  # comma-separated
    feature_store: FeatureStore = Depends(get_feature_store),
) -> Dict[str, Any]:
    """يجيب الـ features الموجودة لـ entity معين"""
    feature_names = [n.strip() for n in names.split(",") if n.strip()]
    if not feature_names:
        return {}
    return await feature_store.get_features(entity_id, feature_names)


# ── Inference Logic ───────────────────────────────────────────────────────

def _run_inference(
    loaded: "LoadedModel",
    features: Dict[str, Any],
) -> tuple[Dict[str, Any], Optional[float]]:
    """
    يشغّل الـ inference حسب الـ framework
    """
    input_feature_names = loaded.input_schema.get("features", list(features.keys()))

    # بناء الـ feature vector بالترتيب الصح
    X = np.array([[features.get(f, 0.0) for f in input_feature_names]], dtype=np.float32)

    framework = loaded.framework
    model = loaded.model_object

    if framework in ("sklearn", "xgboost", "lightgbm"):
        pred = model.predict(X)[0]
        confidence = None
        try:
            proba = model.predict_proba(X)[0]
            confidence = float(max(proba))
        except (AttributeError, Exception):
            pass

        # Shape الـ output حسب الـ model type
        return _shape_output(loaded.model_type, pred, features), confidence

    elif framework == "onnx":
        import onnxruntime as ort
        input_name = model.get_inputs()[0].name
        outputs = model.run(None, {input_name: X})
        pred = outputs[0][0]
        confidence = float(outputs[1][0].max()) if len(outputs) > 1 else None
        return _shape_output(loaded.model_type, pred, features), confidence

    else:
        raise ValueError(f"Runtime inference not implemented for framework: {framework}")


def _shape_output(model_type: str, raw_pred: Any, features: Dict) -> Dict[str, Any]:
    """بيشكّل الـ output حسب نوع الـ model"""
    if model_type == "price_prediction":
        direction = "up" if float(raw_pred) > 0 else "down"
        return {
            "price_change_pct": float(raw_pred),
            "direction": direction,
        }
    elif model_type == "sentiment_analysis":
        labels = ["negative", "neutral", "positive"]
        idx = int(raw_pred) if isinstance(raw_pred, (int, float)) else 1
        return {
            "sentiment": labels[min(idx, 2)],
            "score": float(raw_pred),
        }
    elif model_type == "anomaly_detection":
        is_anomaly = bool(raw_pred == -1) if isinstance(raw_pred, (int, float)) else False
        return {
            "is_anomaly": is_anomaly,
            "anomaly_score": float(raw_pred),
            "severity": "high" if is_anomaly else "normal",
        }
    else:
        return {"value": float(raw_pred) if isinstance(raw_pred, (int, float)) else str(raw_pred)}
