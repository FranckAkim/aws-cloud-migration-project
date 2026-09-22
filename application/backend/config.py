from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_env: str = "development"
    api_port: int = 8000
    log_level: str = "INFO"
    app_version: str = "0.1.0"

    # HS256 needs a key at least as long as its 32-byte hash output.
    secret_key: SecretStr = Field(min_length=32)
    jwt_expiration: int = 60  # minutes

    database_host: str = "localhost"
    database_port: int = 5432
    database_name: str = "novatech"
    database_user: str = "novatech"
    database_password: SecretStr
    # 'prefer' locally (plain container), 'require' against RDS, which
    # refuses unencrypted connections anyway (rds.force_ssl=1).
    database_sslmode: str = "prefer"
    db_pool_min: int = 1
    db_pool_max: int = 5


settings = Settings()
