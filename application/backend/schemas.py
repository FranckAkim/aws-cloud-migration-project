"""Request and response models. Validation here is the polite first line of
defense; the database constraints are the absolute one."""

from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, Field


class ProductIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    sku: str = Field(min_length=1, max_length=64)
    price: Decimal = Field(ge=0, max_digits=10, decimal_places=2)
    quantity: int = Field(ge=0)


class OrderCreate(BaseModel):
    # No user_id: the user comes from the verified token, never the request.
    product_id: int
    quantity: int = Field(gt=0)
    customer_name: str = Field(min_length=1, max_length=200)


class OrderStatusUpdate(BaseModel):
    status: Literal["pending", "shipped", "cancelled"]


class Token(BaseModel):
    access_token: str
    token_type: str
