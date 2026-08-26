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
    secret_key: SecretStr = Field(min_length=16)
    jwt_expiration: int = 60

    database_host: str = "localhost"
    database_port: int = 5432
    database_name: str = "novatech"
    database_user: str = "novatech"
    database_password: SecretStr
    db_pool_min: int = 1
    db_pool_max: int = 5


settings = Settings()

