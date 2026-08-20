import logging

import uvicorn
from fastapi import FastAPI

from config import settings

logging.basicConfig(
    level=settings.log_level,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
logger = logging.getLogger("novatech")

app = FastAPI(title="NovaTech API")

logger.info(
    "Starting NovaTech API | env=%s | port=%s | secret_key_set=%s",
    settings.app_env,
    settings.api_port,
    bool(settings.secret_key.get_secret_value()),
    settings.jwt_expiration,
)


@app.get("/health")
def health():
    return {"status": "healthy", "environment": settings.app_env, "version": "1.0.0",}


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=settings.api_port,
        reload=settings.app_env == "development",
    )
