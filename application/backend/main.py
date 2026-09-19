import logging
import os
from contextlib import asynccontextmanager
from typing import Annotated

import uvicorn
from fastapi import Depends, FastAPI, HTTPException, Response, status
from fastapi.security import OAuth2PasswordRequestForm

import auth
import db
from config import settings
from schemas import OrderCreate, OrderStatusUpdate, ProductIn, Token

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


app = FastAPI(title="NovaTech API", version=settings.app_version, lifespan=lifespan)

# Adding this parameter to an endpoint makes it require a valid token.
CurrentUser = Annotated[int, Depends(auth.get_current_user_id)]


def _not_found(what: str) -> HTTPException:
    return HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"{what} not found")


# -------------------------------------------------------------------- health


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


# ---------------------------------------------------------------------- auth


@app.post("/api/auth/login", response_model=Token)
def login(form: Annotated[OAuth2PasswordRequestForm, Depends()]):
    user = auth.authenticate_user(form.username, form.password)
    if user is None:
        logger.warning("Login failed | email=%s", form.username)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    logger.info("Login succeeded | user_id=%s", user["id"])
    return {"access_token": auth.create_access_token(user["id"]), "token_type": "bearer"}


# ------------------------------------------------------------------ products


@app.get("/api/products")
def list_products(user_id: CurrentUser):
    return db.list_products()


@app.get("/api/products/{product_id}")
def get_product(product_id: int, user_id: CurrentUser):
    product = db.get_product(product_id)
    if product is None:
        raise _not_found("Product")
    return product


@app.post("/api/products", status_code=status.HTTP_201_CREATED)
def create_product(product: ProductIn, user_id: CurrentUser):
    try:
        return db.create_product(product.name, product.sku, product.price, product.quantity)
    except db.Conflict as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))


@app.put("/api/products/{product_id}")
def update_product(product_id: int, product: ProductIn, user_id: CurrentUser):
    try:
        return db.update_product(
            product_id, product.name, product.sku, product.price, product.quantity
        )
    except db.NotFound:
        raise _not_found("Product")
    except db.Conflict as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))


@app.delete("/api/products/{product_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_product(product_id: int, user_id: CurrentUser):
    try:
        db.deactivate_product(product_id)
    except db.NotFound:
        raise _not_found("Product")


# -------------------------------------------------------------------- orders


@app.get("/api/orders")
def list_orders(user_id: CurrentUser):
    return db.list_orders()


@app.get("/api/orders/{order_id}")
def get_order(order_id: int, user_id: CurrentUser):
    order = db.get_order(order_id)
    if order is None:
        raise _not_found("Order")
    return order


@app.post("/api/orders", status_code=status.HTTP_201_CREATED)
def create_order(order: OrderCreate, user_id: CurrentUser):
    try:
        return db.create_order(order.product_id, user_id, order.quantity, order.customer_name)
    except db.NotFound:
        raise _not_found("Product")
    except db.InsufficientStock:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Insufficient stock")


@app.put("/api/orders/{order_id}")
def update_order_status(order_id: int, update: OrderStatusUpdate, user_id: CurrentUser):
    try:
        return db.update_order_status(order_id, update.status)
    except db.NotFound:
        raise _not_found("Order")
    except db.Conflict as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=settings.api_port,
        reload=settings.app_env == "development",
    )
