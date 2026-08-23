CREATE TABLE users (
    id              SERIAL PRIMARY KEY,
    name            TEXT        NOT NULL,
    email           TEXT        NOT NULL UNIQUE,
    password_hash   TEXT        NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE products (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    sku        TEXT NOT NULL UNIQUE,
    price      NUMERIC(10, 2) NOT NULL CHECK (price >= 0),
    quantity   INT NOT NULL CHECK (quantity >= 0),
    is_active  BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE orders (
    id            SERIAL PRIMARY KEY,
    product_id    INT NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    user_id       INT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    quantity      INT NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price >= 0),
    customer_name TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'shipped', 'cancelled')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);