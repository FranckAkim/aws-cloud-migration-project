import logging

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from config import settings

logger = logging.getLogger("novatech")


class ProductNotFound(Exception):
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


def list_products() -> list[dict]:
    with pool.connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT id, name, sku, price, quantity, created_at
                FROM products
                WHERE is_active = TRUE
                ORDER BY name
                """
            )
            return cur.fetchall()


def get_product(product_id: int) -> dict | None:
    with pool.connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT id, name, sku, price, quantity, created_at
                FROM products
                WHERE id = %s AND is_active = TRUE
                """,
                (product_id,),
            )
            return cur.fetchone()


def create_order(
    product_id: int, user_id: int, quantity: int, customer_name: str
) -> dict:
    with pool.connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                "SELECT price FROM products WHERE id = %s AND is_active = TRUE",
                (product_id,),
            )
            product = cur.fetchone()
            if product is None:
                raise ProductNotFound(product_id)

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


