"""Database access. Every query is parameterised; user input never becomes SQL."""

import logging
from decimal import Decimal

from psycopg import errors
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from config import settings

logger = logging.getLogger("novatech")


class NotFound(Exception):
    pass


class Conflict(Exception):
    pass


class InsufficientStock(Exception):
    pass


def _conninfo() -> str:
    return (
        f"host={settings.database_host} "
        f"port={settings.database_port} "
        f"dbname={settings.database_name} "
        f"user={settings.database_user} "
        f"password={settings.database_password.get_secret_value()} "
        f"sslmode={settings.database_sslmode} "
        f"connect_timeout=3"
    )


pool = ConnectionPool(
    conninfo=_conninfo(),
    min_size=settings.db_pool_min,
    max_size=settings.db_pool_max,
    open=False,
)


def check_database() -> bool:
    """Cheap readiness probe. True if the database answers, False otherwise."""
    try:
        with pool.connection(timeout=2) as conn:
            conn.execute("SELECT 1")
        return True
    except Exception as exc:
        logger.warning("Database check failed: %s", exc)
        return False


# --------------------------------------------------------------------- users


def get_user_by_email(email: str) -> dict | None:
    with pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            "SELECT id, name, email, password_hash FROM users WHERE email = %s",
            (email,),
        )
        return cur.fetchone()


def create_user(name: str, email: str, password_hash: str) -> dict:
    try:
        with pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                INSERT INTO users (name, email, password_hash)
                VALUES (%s, %s, %s)
                RETURNING id, name, email, created_at
                """,
                (name, email, password_hash),
            )
            return cur.fetchone()
    except errors.UniqueViolation as exc:
        raise Conflict("A user with this email already exists") from exc


# ------------------------------------------------------------------ products


def list_products() -> list[dict]:
    with pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT id, name, sku, price, quantity, created_at, updated_at
            FROM products
            WHERE is_active = TRUE
            ORDER BY name
            """
        )
        return cur.fetchall()


def get_product(product_id: int) -> dict | None:
    with pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT id, name, sku, price, quantity, created_at, updated_at
            FROM products
            WHERE id = %s AND is_active = TRUE
            """,
            (product_id,),
        )
        return cur.fetchone()


def create_product(name: str, sku: str, price: Decimal, quantity: int) -> dict:
    try:
        with pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                INSERT INTO products (name, sku, price, quantity)
                VALUES (%s, %s, %s, %s)
                RETURNING id, name, sku, price, quantity, created_at, updated_at
                """,
                (name, sku, price, quantity),
            )
            return cur.fetchone()
    except errors.UniqueViolation as exc:
        raise Conflict("A product with this SKU already exists") from exc


def update_product(
    product_id: int, name: str, sku: str, price: Decimal, quantity: int
) -> dict:
    try:
        with pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                UPDATE products
                SET name = %s, sku = %s, price = %s, quantity = %s,
                    updated_at = NOW()
                WHERE id = %s AND is_active = TRUE
                RETURNING id, name, sku, price, quantity, created_at, updated_at
                """,
                (name, sku, price, quantity, product_id),
            )
            product = cur.fetchone()
    except errors.UniqueViolation as exc:
        raise Conflict("A product with this SKU already exists") from exc
    if product is None:
        raise NotFound(product_id)
    return product


def deactivate_product(product_id: int) -> None:
    """Soft delete: the row stays so historical orders keep their reference."""
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE products SET is_active = FALSE, updated_at = NOW()
            WHERE id = %s AND is_active = TRUE
            """,
            (product_id,),
        )
        if cur.rowcount == 0:
            raise NotFound(product_id)


# -------------------------------------------------------------------- orders


def list_orders(limit: int = 100) -> list[dict]:
    with pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT id, product_id, user_id, quantity, unit_price,
                   customer_name, status, created_at
            FROM orders
            ORDER BY created_at DESC, id DESC
            LIMIT %s
            """,
            (limit,),
        )
        return cur.fetchall()


def get_order(order_id: int) -> dict | None:
    with pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT id, product_id, user_id, quantity, unit_price,
                   customer_name, status, created_at
            FROM orders
            WHERE id = %s
            """,
            (order_id,),
        )
        return cur.fetchone()


def create_order(
    product_id: int, user_id: int, quantity: int, customer_name: str
) -> dict:
    """Decrement stock and record the order in ONE transaction.

    The `with pool.connection()` block is the transaction: it commits on normal
    exit and rolls back if any exception escapes, so a failed order leaves no
    trace. The conditional UPDATE lets the database arbitrate the race for the
    last unit; rowcount == 0 means we lost it.
    """
    with pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            "SELECT price FROM products WHERE id = %s AND is_active = TRUE",
            (product_id,),
        )
        product = cur.fetchone()
        if product is None:
            raise NotFound(product_id)

        cur.execute(
            """
            UPDATE products
            SET quantity = quantity - %s, updated_at = NOW()
            WHERE id = %s AND is_active = TRUE AND quantity >= %s
            """,
            (quantity, product_id, quantity),
        )
        if cur.rowcount == 0:
            raise InsufficientStock(product_id)

        cur.execute(
            """
            INSERT INTO orders
                (product_id, user_id, quantity, unit_price, customer_name)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING id, product_id, user_id, quantity, unit_price,
                      customer_name, status, created_at
            """,
            (product_id, user_id, quantity, product["price"], customer_name),
        )
        return cur.fetchone()


# Which status changes are allowed. Shipped and cancelled are final.
ALLOWED_TRANSITIONS = {"pending": {"shipped", "cancelled"}}


def update_order_status(order_id: int, new_status: str) -> dict:
    """Change an order's status; cancelling a pending order returns its stock.

    SELECT ... FOR UPDATE locks the order row so two simultaneous requests
    can't both cancel it and restock twice (pessimistic locking).
    """
    with pool.connection() as conn, conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT id, product_id, quantity, status
            FROM orders WHERE id = %s FOR UPDATE
            """,
            (order_id,),
        )
        order = cur.fetchone()
        if order is None:
            raise NotFound(order_id)

        if new_status != order["status"]:
            if new_status not in ALLOWED_TRANSITIONS.get(order["status"], set()):
                raise Conflict(
                    f"Cannot change an order from {order['status']} to {new_status}"
                )
            if new_status == "cancelled":
                cur.execute(
                    """
                    UPDATE products
                    SET quantity = quantity + %s, updated_at = NOW()
                    WHERE id = %s
                    """,
                    (order["quantity"], order["product_id"]),
                )
            cur.execute(
                "UPDATE orders SET status = %s WHERE id = %s",
                (new_status, order_id),
            )

        cur.execute(
            """
            SELECT id, product_id, user_id, quantity, unit_price,
                   customer_name, status, created_at
            FROM orders WHERE id = %s
            """,
            (order_id,),
        )
        return cur.fetchone()
