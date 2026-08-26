import logging
import os
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, HTTPException, Response, status

import db
from config import settings

from pydantic import BaseModel, Field


logging.basicConfig(
    level=settings.log_level,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
logger = logging.getLogger("novatech")


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(
        "Starting NovaTech API | pid=%s | env=%s | version=%s | port=%s | db=%s:%s | secret_key_set=%s",
        os.getpid(),
        settings.app_env,
        settings.app_version,
        settings.api_port,
        settings.database_host,
        settings.database_port,
        bool(settings.secret_key.get_secret_value()),
    )
    db.pool.open()
    yield
    db.pool.close()
    logger.info("NovaTech API stopped | pid=%s", os.getpid())


app = FastAPI(title="NovaTech API", lifespan=lifespan)


@app.get("/health")
def health(response: Response):
    database_ok = db.check_database()
    if not database_ok:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return {
        "status": "healthy" if database_ok else "unhealthy",
        "environment": settings.app_env,
        "version": settings.app_version,
        "database": "up" if database_ok else "down",
    }


@app.get("/api/products")
def list_products():
    return db.list_products()


@app.get("/api/products/{product_id}")
def get_product(product_id: int):
    product = db.get_product(product_id)
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found")
    return product


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=settings.api_port,
        reload=settings.app_env == "development",
    )

class OrderCreate(BaseModel):
    product_id: int
    user_id: int
    quantity: int = Field(gt=0)
    customer_name: str = Field(min_length=1, max_length=200)


@app.post("/api/orders", status_code=201)
def create_order(order: OrderCreate):
    try:
        return db.create_order(
            order.product_id, order.user_id, order.quantity, order.customer_name
        )
    except db.ProductNotFound:
        raise HTTPException(status_code=404, detail="Product not found")
    except db.InsufficientStock:
        raise HTTPException(status_code=409, detail="Insufficient stock")
