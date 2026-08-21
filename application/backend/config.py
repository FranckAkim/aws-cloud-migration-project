from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import SecretStr
from pydantic import Field, SecretStr



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


settings = Settings()
