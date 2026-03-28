"""
Model Registry — loads and caches ML models from S3
بيحمّل الـ models من S3 عند الـ startup ويحتفظ بيهم في الـ memory
"""
from __future__ import annotations

import asyncio
import logging
import time
from typing import Any, Dict, Optional
from dataclasses import dataclass, field

import boto3
import joblib

logger = logging.getLogger(__name__)


@dataclass
class LoadedModel:
    model_id: str
    name: str
    version: str
    model_type: str
    framework: str
    artifact_path: str
    model_object: Any
    input_schema: Dict
    output_schema: Dict
    loaded_at: float = field(default_factory=time.time)

    def is_stale(self, max_age_seconds: int = 3600) -> bool:
        return time.time() - self.loaded_at > max_age_seconds


class ModelRegistry:
    """
    Singleton — يُستخدم كـ FastAPI dependency
    بيحمّل الـ production models من S3 عند الـ startup
    """

    def __init__(self, bucket: str, aws_region: str):
        self._bucket = bucket
        self._s3 = boto3.client("s3", region_name=aws_region)
        self._models: Dict[str, LoadedModel] = {}  # key: model_type
        self._lock = asyncio.Lock()

    async def load_production_models(self, db_models: list[dict]) -> None:
        """يحمّل كل الـ production models من DB records"""
        async with self._lock:
            for record in db_models:
                try:
                    loaded = await asyncio.get_event_loop().run_in_executor(
                        None, self._load_from_s3, record
                    )
                    self._models[record["type"]] = loaded
                    logger.info(
                        "model loaded",
                        extra={
                            "model_name": record["name"],
                            "version": record["version"],
                            "type": record["type"],
                        },
                    )
                except Exception as e:
                    logger.error(
                        "failed to load model",
                        extra={"model": record["name"], "error": str(e)},
                    )

    def _load_from_s3(self, record: dict) -> LoadedModel:
        """Download + deserialize model artifact from S3"""
        import tempfile
        import os

        path = record["artifact_path"]
        # s3://bucket/key → bucket, key
        path_without_scheme = path.replace("s3://", "")
        parts = path_without_scheme.split("/", 1)
        bucket = parts[0]
        key = parts[1] if len(parts) > 1 else ""

        with tempfile.NamedTemporaryFile(suffix=self._suffix(record["framework"]), delete=False) as tmp:
            self._s3.download_fileobj(bucket, key, tmp)
            tmp_path = tmp.name

        try:
            model_obj = self._deserialize(tmp_path, record["framework"])
        finally:
            os.unlink(tmp_path)

        return LoadedModel(
            model_id=record["id"],
            name=record["name"],
            version=record["version"],
            model_type=record["type"],
            framework=record["framework"],
            artifact_path=path,
            model_object=model_obj,
            input_schema=record.get("input_schema", {}),
            output_schema=record.get("output_schema", {}),
        )

    def _deserialize(self, path: str, framework: str) -> Any:
        if framework in ("sklearn", "xgboost", "lightgbm"):
            return joblib.load(path)
        elif framework == "onnx":
            import onnxruntime as ort
            return ort.InferenceSession(path)
        elif framework == "pytorch":
            import torch
            return torch.load(path, map_location="cpu", weights_only=False)
        else:
            raise ValueError(f"Unsupported framework: {framework}")

    def _suffix(self, framework: str) -> str:
        mapping = {
            "sklearn": ".pkl", "xgboost": ".json", "lightgbm": ".txt",
            "onnx": ".onnx", "pytorch": ".pt", "tensorflow": ".h5",
        }
        return mapping.get(framework, ".bin")

    def get(self, model_type: str) -> Optional[LoadedModel]:
        return self._models.get(model_type)

    def list_loaded(self) -> list[str]:
        return list(self._models.keys())

    async def reload(self, model_type: str, record: dict) -> None:
        """Hot reload — يستبدل model بدون restart"""
        async with self._lock:
            loaded = await asyncio.get_event_loop().run_in_executor(
                None, self._load_from_s3, record
            )
            self._models[model_type] = loaded
            logger.info("model reloaded", extra={"type": model_type})
