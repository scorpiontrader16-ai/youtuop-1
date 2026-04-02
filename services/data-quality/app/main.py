# ─────────────────────────────────────────────────────────────────────────────
# Data Quality Service — HTTP API for triggering Soda Core checks
# لماذا: نحتاج endpoint موحد لتشغيل data quality checks من أي service أو scheduler
# ─────────────────────────────────────────────────────────────────────────────
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException
from prometheus_client import Counter, Histogram, make_asgi_app
from pydantic import BaseModel
from pydantic_settings import BaseSettings
from pydantic import field_validator

logger = logging.getLogger(__name__)


class Settings(BaseSettings):
    postgres_host: str = "postgres"
    postgres_port: int = 5432
    postgres_db: str = "platform"
    postgres_user: str = "platform"
    postgres_password: str = ""  # لازم يجيء من POSTGRES_PASSWORD env var
    postgres_ssl_mode: str = "require"  # TLS مطلوب
    contracts_dir: str = "/app/contracts"
    version: str = "dev"

    class Config:
        env_file = ".env"

    @field_validator("postgres_password")
    @classmethod
    def validate_postgres_password(cls, v: str) -> str:
        # PostgreSQL password must be injected from ExternalSecrets (AWS Secrets Manager)
        # Never use hardcoded or default passwords — fail at startup to prevent
        # security issues from weak credentials reaching production.
        if not v or v.strip() == "":
            raise ValueError("CRITICAL: POSTGRES_PASSWORD environment variable is required but not set")
        return v


settings = Settings()

# ── Metrics ───────────────────────────────────────────────────────────────────
checks_total = Counter(
    "dq_checks_total",
    "Total data quality checks run",
    ["contract", "status"],
)
check_duration = Histogram(
    "dq_check_duration_seconds",
    "Duration of data quality checks",
    ["contract"],
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("data-quality service starting", extra={"version": settings.version})
    yield
    logger.info("data-quality service shutting down")


app = FastAPI(
    title="data-quality",
    version=settings.version,
    lifespan=lifespan,
)

# Prometheus metrics endpoint
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)


class CheckRequest(BaseModel):
    contract: str  # اسم الـ contract بدون .yaml
    datasource: str = "platform-postgres"


class CheckResult(BaseModel):
    contract: str
    passed: bool
    duration_seconds: float
    details: dict[str, Any]


@app.get("/healthz")
async def health() -> dict:
    # لماذا: Kubernetes liveness probe يحتاج endpoint بسيط
    return {"status": "ok", "version": settings.version}


@app.get("/readyz")
async def ready() -> dict:
    # لماذا: readiness probe — نتحقق من إمكانية الوصول لـ contracts
    contracts_dir = settings.contracts_dir
    if not os.path.isdir(contracts_dir):
        raise HTTPException(status_code=503, detail="contracts directory not found")
    return {"status": "ready"}


@app.post("/checks/run", response_model=CheckResult)
async def run_check(req: CheckRequest) -> CheckResult:
    # لماذا: نقطة دخول موحدة لتشغيل أي contract check
    contract_path = os.path.join(settings.contracts_dir, f"{req.contract}.yaml")
    if not os.path.exists(contract_path):
        raise HTTPException(
            status_code=404,
            detail=f"contract {req.contract} not found at {contract_path}",
        )

    start = time.perf_counter()
    try:
        from soda.scan import Scan

        scan = Scan()
        scan.set_data_source_name(req.datasource)
        scan.add_configuration_yaml_str(
            f"""
data_sources:
  {req.datasource}:
    type: postgres
    host: {settings.postgres_host}
    port: {settings.postgres_port}
    database: {settings.postgres_db}
    username: {settings.postgres_user}
    password: {settings.postgres_password}
"""
        )
        scan.add_sodacl_yaml_file(contract_path)
        scan.execute()

        duration = time.perf_counter() - start
        passed = not scan.has_check_fails()
        status = "pass" if passed else "fail"
        checks_total.labels(contract=req.contract, status=status).inc()
        check_duration.labels(contract=req.contract).observe(duration)

        return CheckResult(
            contract=req.contract,
            passed=passed,
            duration_seconds=round(duration, 3),
            details={
                "checks_passed": scan.get_checks_count() - scan.get_checks_fail_count(),
                "checks_failed": scan.get_checks_fail_count(),
                "checks_total": scan.get_checks_count(),
            },
        )
    except Exception as exc:
        duration = time.perf_counter() - start
        checks_total.labels(contract=req.contract, status="error").inc()
        logger.error("check failed", extra={"contract": req.contract, "error": str(exc)})
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.get("/checks/contracts")
async def list_contracts() -> dict:
    # لماذا: يسمح لأي client بمعرفة الـ contracts المتاحة
    contracts_dir = settings.contracts_dir
    if not os.path.isdir(contracts_dir):
        return {"contracts": []}
    contracts = [
        f.replace(".yaml", "")
        for f in os.listdir(contracts_dir)
        if f.endswith(".yaml")
    ]
    return {"contracts": sorted(contracts)}
