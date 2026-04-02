from pydantic_settings import BaseSettings
from pydantic import field_validator
from functools import lru_cache


class Settings(BaseSettings):
    # Server
    host: str = "0.0.0.0"
    port: int = 9098
    workers: int = 2
    version: str = "dev"

    # Database
    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_db: str = "platform"
    postgres_user: str = "platform"
    postgres_password: str = ""  # لازم يجيء من POSTGRES_PASSWORD env var
    postgres_ssl_mode: str = "require"  # TLS مطلوب

    # Redis (feature cache)
    redis_addr: str = "redis:6379"
    redis_password: str = ""
    feature_cache_ttl: int = 300  # 5 minutes

    # AWS S3 (model artifacts)
    aws_region: str = "us-east-1"
    model_artifacts_bucket: str = "platform-ml-artifacts"

    # OTel
    otel_endpoint: str = "otel-collector:4317"

    # Model serving
    model_load_timeout: int = 30
    inference_timeout: int = 10
    max_batch_size: int = 64

    class Config:
        env_file = ".env"
        case_sensitive = False

    @field_validator("postgres_password")
    @classmethod
    def validate_postgres_password(cls, v: str) -> str:
        # PostgreSQL password must be injected from ExternalSecrets (AWS Secrets Manager)
        # Never use hardcoded or default passwords — fail at startup to prevent
        # security issues from weak credentials reaching production.
        if not v or v.strip() == "":
            raise ValueError("CRITICAL: POSTGRES_PASSWORD environment variable is required but not set")
        return v

    @property
    def postgres_dsn(self) -> str:
        return (
            f"postgresql+asyncpg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
