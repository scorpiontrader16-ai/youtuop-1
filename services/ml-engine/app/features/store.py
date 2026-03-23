"""
Online Feature Store — Redis-backed للـ low-latency inference
بيجيب الـ features من Redis أو يحسبها من الـ DB لو مش موجودة
"""
from __future__ import annotations

import json
import logging
from typing import Any, Dict, List, Optional

import redis.asyncio as aioredis

logger = logging.getLogger(__name__)

# Feature cache key format: ff:{entity_id}:{feature_name}
CACHE_KEY = "ff:{entity_id}:{feature_name}"


class FeatureStore:
    """
    Online Feature Store — بيجيب الـ features للـ inference
    الـ features بتتحسب من الـ processing service وبتتحفظ في Redis
    """

    def __init__(self, redis_client: aioredis.Redis, default_ttl: int = 300):
        self._redis = redis_client
        self._default_ttl = default_ttl

    async def get_features(
        self,
        entity_id: str,
        feature_names: List[str],
    ) -> Dict[str, Optional[Any]]:
        """
        يجيب مجموعة features لـ entity معين
        بيستخدم Redis pipeline للـ performance
        """
        if not feature_names:
            return {}

        keys = [CACHE_KEY.format(entity_id=entity_id, feature_name=f) for f in feature_names]

        async with self._redis.pipeline(transaction=False) as pipe:
            for key in keys:
                pipe.get(key)
            values = await pipe.execute()

        result: Dict[str, Optional[Any]] = {}
        for name, raw in zip(feature_names, values):
            if raw is not None:
                try:
                    result[name] = json.loads(raw)
                except json.JSONDecodeError:
                    result[name] = None
                    logger.warning("invalid feature value in cache", extra={"key": name})
            else:
                result[name] = None

        missing = [n for n, v in result.items() if v is None]
        if missing:
            logger.debug(
                "feature cache miss",
                extra={"entity_id": entity_id, "missing": missing},
            )

        return result

    async def set_features(
        self,
        entity_id: str,
        features: Dict[str, Any],
        ttl: Optional[int] = None,
    ) -> None:
        """
        يحفظ features في Redis — بيُستدعى من الـ processing service
        """
        effective_ttl = ttl or self._default_ttl
        async with self._redis.pipeline(transaction=False) as pipe:
            for name, value in features.items():
                key = CACHE_KEY.format(entity_id=entity_id, feature_name=name)
                pipe.setex(key, effective_ttl, json.dumps(value))
            await pipe.execute()

    async def get_feature_vector(
        self,
        entity_id: str,
        feature_names: List[str],
        defaults: Optional[Dict[str, Any]] = None,
    ) -> List[float]:
        """
        يرجع feature vector بترتيب محدد — للـ model inference مباشرة
        المفقود يأخذ default value أو 0.0
        """
        features = await self.get_features(entity_id, feature_names)
        defaults = defaults or {}

        vector = []
        for name in feature_names:
            val = features.get(name)
            if val is None:
                val = defaults.get(name, 0.0)
            try:
                vector.append(float(val))
            except (TypeError, ValueError):
                vector.append(0.0)

        return vector

    async def invalidate(self, entity_id: str, feature_names: Optional[List[str]] = None) -> None:
        """يمسح features من الـ cache"""
        if feature_names:
            keys = [CACHE_KEY.format(entity_id=entity_id, feature_name=f) for f in feature_names]
        else:
            pattern = CACHE_KEY.format(entity_id=entity_id, feature_name="*")
            keys = [k async for k in self._redis.scan_iter(pattern)]

        if keys:
            await self._redis.delete(*keys)
