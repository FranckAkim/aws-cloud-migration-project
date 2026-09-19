"""Test setup. These tests DROP and recreate every table, so they refuse to run
unless DATABASE_NAME ends in `_test`. Never point them at a real database."""

import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "application" / "backend"))

if not os.environ.get("DATABASE_NAME", "").endswith("_test"):
    pytest.exit(
        "Refusing to run: DATABASE_NAME must end in '_test' (these tests wipe the database).",
        returncode=2,
    )

from fastapi.testclient import TestClient  # noqa: E402

import auth  # noqa: E402
import db  # noqa: E402
import main  # noqa: E402

SCHEMA = (ROOT / "application" / "database" / "01-schema.sql").read_text()
PASSWORD = "correct-horse-battery"


@pytest.fixture(scope="session")
def client():
    with TestClient(main.app) as c:
        yield c


@pytest.fixture(autouse=True)
def clean_database(client):
    with db.pool.connection() as conn:
        conn.execute("DROP TABLE IF EXISTS orders, products, users CASCADE")
        conn.execute(SCHEMA)
    yield


@pytest.fixture
def user():
    return db.create_user("Dee", "dee@novatech.test", auth.hash_password(PASSWORD))


@pytest.fixture
def headers(client, user):
    r = client.post("/api/auth/login", data={"username": user["email"], "password": PASSWORD})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


@pytest.fixture
def product(client, headers):
    r = client.post(
        "/api/products",
        json={"name": "Wireless Mouse", "sku": "SKU-001", "price": "24.99", "quantity": 5},
        headers=headers,
    )
    assert r.status_code == 201, r.text
    return r.json()
