from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import SecretStr



class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_env: str = "development"
    api_port: int = 8000
    log_level: str = "INFO"
    secret_key: SecretStr
    jwt_expiration: int = 60


settings = Settings()
