import threading
from datetime import datetime, timedelta, timezone

import jwt

import db
from config import settings


def stock(client, headers, product_id):
    return client.get(f"/api/products/{product_id}", headers=headers).json()["quantity"]


# ---------------------------------------------------------------- health/auth


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["database"] == "up"


def test_protected_endpoints_require_a_token(client):
    assert client.get("/api/products").status_code == 401
    assert client.get("/api/orders").status_code == 401


def test_login_rejects_bad_credentials_identically(client, user):
    wrong_pw = client.post("/api/auth/login", data={"username": user["email"], "password": "nope"})
    no_user = client.post("/api/auth/login", data={"username": "ghost@x.test", "password": "nope"})
    assert wrong_pw.status_code == no_user.status_code == 401
    assert wrong_pw.json() == no_user.json()  # no hint about which emails exist


def test_login_normalises_email(client, user):
    r = client.post("/api/auth/login", data={"username": " DEE@novatech.test ", "password": "correct-horse-battery"})
    assert r.status_code == 200


def test_invalid_tokens_are_rejected(client, user):
    key = settings.secret_key.get_secret_value()
    now = datetime.now(timezone.utc)
    tokens = {
        "expired": jwt.encode({"sub": str(user["id"]), "exp": now - timedelta(minutes=1)}, key, algorithm="HS256"),
        "wrong key": jwt.encode({"sub": str(user["id"])}, "x" * 48, algorithm="HS256"),
        "unsigned": jwt.encode({"sub": str(user["id"])}, None, algorithm="none"),
    }
    for name, token in tokens.items():
        r = client.get("/api/products", headers={"Authorization": f"Bearer {token}"})
        assert r.status_code == 401, name


def test_duplicate_user_is_a_conflict(user):
    try:
        db.create_user("Dup", user["email"], "x")
    except db.Conflict:
        return
    raise AssertionError("expected Conflict")


# ------------------------------------------------------------------ products


def test_product_crud_and_soft_delete(client, headers, product):
    pid = product["id"]
    dup = client.post("/api/products", json={"name": "X", "sku": "SKU-001", "price": "1", "quantity": 1}, headers=headers)
    assert dup.status_code == 409

    r = client.put(f"/api/products/{pid}", json={"name": "Mouse v2", "sku": "SKU-001", "price": "25.00", "quantity": 5}, headers=headers)
    assert r.status_code == 200 and r.json()["name"] == "Mouse v2"

    assert client.delete(f"/api/products/{pid}", headers=headers).status_code == 204
    assert client.get(f"/api/products/{pid}", headers=headers).status_code == 404
    assert client.delete(f"/api/products/{pid}", headers=headers).status_code == 404
    assert client.get("/api/products", headers=headers).json() == []


def test_product_validation(client, headers):
    r = client.post("/api/products", json={"name": "X", "sku": "S", "price": "-1", "quantity": 1}, headers=headers)
    assert r.status_code == 422


# -------------------------------------------------------------------- orders


def test_order_decrements_stock_and_uses_token_identity(client, headers, user, product):
    r = client.post(
        "/api/orders",
        json={"product_id": product["id"], "quantity": 2, "customer_name": "Acme", "user_id": 999},
        headers=headers,
    )
    assert r.status_code == 201
    assert r.json()["user_id"] == user["id"]  # body's user_id is ignored
    assert r.json()["status"] == "pending"
    assert stock(client, headers, product["id"]) == 3


def test_failed_order_rolls_back(client, headers, product):
    r = client.post("/api/orders", json={"product_id": product["id"], "quantity": 999, "customer_name": "Greedy"}, headers=headers)
    assert r.status_code == 409
    assert stock(client, headers, product["id"]) == 5
    assert client.get("/api/orders", headers=headers).json() == []


def test_order_status_transitions(client, headers, product):
    oid = client.post("/api/orders", json={"product_id": product["id"], "quantity": 2, "customer_name": "Acme"}, headers=headers).json()["id"]

    r = client.put(f"/api/orders/{oid}", json={"status": "cancelled"}, headers=headers)
    assert r.status_code == 200 and r.json()["status"] == "cancelled"
    assert stock(client, headers, product["id"]) == 5  # restocked

    assert client.put(f"/api/orders/{oid}", json={"status": "cancelled"}, headers=headers).status_code == 200
    assert stock(client, headers, product["id"]) == 5  # idempotent: no double restock
    assert client.put(f"/api/orders/{oid}", json={"status": "shipped"}, headers=headers).status_code == 409
    assert client.put(f"/api/orders/{oid}", json={"status": "lost"}, headers=headers).status_code == 422


# --------------------------------------------------------------- concurrency


def test_race_for_last_units_never_oversells(client, headers, user, product):
    results = []

    def buy():
        try:
            db.create_order(product["id"], user["id"], 1, "Racer")
            results.append("ok")
        except db.InsufficientStock:
            results.append("sold out")

    threads = [threading.Thread(target=buy) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert results.count("ok") == 5
    assert stock(client, headers, product["id"]) == 0


def test_concurrent_cancellations_restock_once(client, headers, user, product):
    order = db.create_order(product["id"], user["id"], 2, "Acme")
    threads = [threading.Thread(target=db.update_order_status, args=(order["id"], "cancelled")) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert stock(client, headers, product["id"]) == 5
