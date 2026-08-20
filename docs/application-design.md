# NovaTech Application Design

## Purpose

NovaTech Solutions is a small inventory and order management application for small businesses. The first version is intentionally limited so that the application can be migrated from on-premises infrastructure to AWS without unnecessary application complexity.

The application allows employees to log in, manage inventory, and create and view orders.

---

## 1. Data Model

### Users

Stores the users who are allowed to access the application.

| Column          | Purpose                                                    |
|-----------------|------------------------------------------------------------|
| `id`            | Primary key                                                |
| `name`          | User's name                                                |
| `email`         | Unique login email                                         |
| `password_hash` | Securely hashed password (never the plaintext password)    |
| `created_at`    | When the user record was created                           |
| `updated_at`    | When the user record was last modified                     |

### Products

Stores inventory items.

| Column            | Purpose                                           |
|-------------------|---------------------------------------------------|
| `id`              | Primary key                                       |
| `name`            | Product name                                      |
| `sku`             | Product identifier, unique among active products  |
| `price`           | Current selling price                             |
| `quantity`        | Current inventory quantity on hand                |
| `is_active`       | Whether the product is available for new orders   |
| `created_at`      | When the product was created                      |
| `updated_at`      | When the product was last modified                |

`is_active` is used instead of permanently deleting products, which preserves historical order information (see Section 4).

**SKU uniqueness note.** A soft-deleted product keeps its row and therefore its SKU. If `sku` carried a simple unique constraint across the whole table, a retired SKU could never be reused. NovaTech accepts that constraint for the first version — SKUs are not reused — because the alternative (a partial unique index scoped to active products) adds complexity without business value at this size.

### Orders

Stores customer orders.

| Column            | Purpose                                                    |
|-------------------|------------------------------------------------------------|
| `id`              | Primary key                                                |
| `product_id`      | Foreign key referencing the ordered product                |
| `user_id`         | Foreign key referencing the employee who created the order |
| `quantity`        | Number of units ordered                                    |
| `unit_price`      | Product price at the time the order was created            |
| `customer_name`   | Name of the customer                                       |
| `status`          | Current order status                                       |
| `created_at`      | Time the order was created                                 |

**`unit_price` is stored on the order deliberately.** The order must preserve the price that existed when the transaction occurred. If a product's price changes later, historical orders must not change value retroactively. A transactional record snapshots the facts as they were; it does not reference facts that can move.

**`user_id` provides the audit trail.** Every order records which employee created it. Without this, the system cannot answer "who entered this order?" — a question that arises in every real business the moment something goes wrong.

**Foreign key constraints are enforced at the database level** on `orders.product_id` and `orders.user_id`. Soft deletion is an application policy; the foreign key is the database-level enforcement that makes referential integrity guaranteed rather than merely intended.

### Deliberate Simplification

Each order contains **one product only** in the first version.

This is a deliberate simplification, not an oversight. The goal of this project is to build and migrate a small realistic application, not to implement a complete e-commerce platform. A future version would introduce an `order_items` table so that one order can contain many line items, with `unit_price` moving to that table.

---

## 2. API Endpoints

### Health

`GET /health` — returns HTTP 200 when the application and its database connection are healthy. A non-200 response indicates the instance should not receive normal application traffic. Requires no authentication. See Section 5.

### Authentication

`POST /api/auth/login` — authenticates a user by email and password, returns a signed JWT.

`POST /api/auth/logout` — client-side logout. The frontend discards the token. Because JWTs are stateless, the server does not invalidate the token; see Section 3 for the consequences.

### Products

`GET /api/products` — returns active products in the inventory.

`POST /api/products` — creates a new product.

`GET /api/products/:id` — returns a specific product.

`PUT /api/products/:id` — updates a product's information or inventory quantity.

`DELETE /api/products/:id` — soft-deletes a product by setting `is_active = false` rather than removing the row.

### Orders

`GET /api/orders` — returns orders.

`POST /api/orders` — creates an order and decrements inventory. See "Order creation semantics" below.

`GET /api/orders/:id` — returns a specific order.

`PUT /api/orders/:id` — updates an order's allowed fields, such as its status.

All endpoints under `/api/` except `/api/auth/login` require a valid JWT.

### Order creation semantics

Creating an order is not a single write. It is two changes that must both happen or neither happen:

1. Insert the order row, capturing the product's current price as `unit_price`.
2. Decrement `products.quantity` by the ordered quantity.

**Atomicity.** These two writes execute inside a single database transaction. If the process crashes between them, the transaction rolls back and neither change persists. Without a transaction, a crash at the wrong moment sells stock the system still believes it holds — the inventory count silently diverges from reality, and nothing in the application ever notices.

**Insufficient stock.** If `quantity` on hand is less than the requested quantity, the order is rejected with HTTP 409 Conflict and no changes are written.

**Concurrency.** Two orders for the last remaining unit can arrive at the same instant. If both read `quantity = 1` before either writes, both conclude the item is in stock and both succeed — the classic oversell. NovaTech prevents this by performing the stock check and the decrement as a single conditional update inside the transaction (`UPDATE products SET quantity = quantity - :n WHERE id = :id AND quantity >= :n`), so the database, not the application, arbitrates the race. If that update affects zero rows, the order is rejected.

This matters more after the migration than before it: on-premises NovaTech runs one application process, so concurrent orders are rare. The target AWS architecture runs **two or more instances behind a load balancer**, which makes genuinely simultaneous requests routine. Correctness that was accidental on one server must be explicit on many.

---

## 3. Authentication

NovaTech uses **stateless JWT authentication**.

A user logs in with an email address and password. The server verifies the password against the stored hash and returns a signed JSON Web Token. The frontend sends that token with subsequent protected API requests. Application instances store no login sessions in local memory; each instance independently verifies the token's signature using the configured signing secret.

**Why this fits the target architecture.** NovaTech will run multiple application instances behind an AWS Application Load Balancer. A request may reach any instance. With in-memory sessions, a user authenticated on instance A appears logged out when their next request lands on instance B. The alternatives are sticky sessions (the load balancer pins each user to one instance — which breaks when that instance dies and undermines even load distribution) or a shared session store such as Redis (correct, but an additional component to run, secure, and pay for). Stateless tokens avoid both.

**The trade-off, stated plainly.** Because verification requires no shared state, **a JWT cannot be revoked before it expires.** A stolen token remains valid until expiry. An employee who is terminated retains access until their token lapses. Logout is therefore client-side only: the frontend discards the token, but the token itself remains cryptographically valid.

NovaTech accepts this trade-off, mitigated by a **short token lifetime of 60 minutes** (`JWT_EXPIRATION`). This bounds the exposure window while keeping the system stateless. A future version could add refresh tokens for usability, or a revocation denylist for immediate invalidation — noting that a denylist reintroduces exactly the shared state that JWTs were chosen to avoid.

**Secret handling.** The JWT signing secret is never hardcoded in source and never committed to Git. It is supplied through environment-specific configuration (`SECRET_KEY`), and in AWS will be sourced from AWS Secrets Manager. Rotating the secret invalidates every outstanding token, which is a blunt but effective emergency revocation mechanism.

---

## 4. Product Deletion Strategy

Products use **soft deletion**.

Deleting a product sets `is_active = false` rather than removing the row. The product no longer appears in inventory listings and cannot be added to new orders, while existing orders that reference it remain intact and valid.

**Why not hard deletion.** Orders are transactional historical records. Removing a product row would either violate the foreign key constraint on `orders.product_id` or, if cascading deletion were configured, destroy order history along with the product. Neither outcome is acceptable for records the business relies on for revenue reporting.

**Consequence to be aware of.** Every query that lists or searches products must filter on `is_active = true`. A single query that forgets the filter leaks retired products back into the application. This is the standard cost of soft deletion and the reason the filter belongs in a shared query path rather than being repeated by hand at each call site.

---

## 5. Health Check Design

`GET /health` verifies two things:

1. The application process is running and able to serve a request.
2. The application can successfully reach the database (a trivial `SELECT 1` with a short timeout).

A successful check returns HTTP 200. If the process is alive but the database is unreachable, the endpoint returns a non-200 response so the Application Load Balancer removes the instance from rotation.

**Requirements on the check itself.** It must be cheap, because the load balancer calls it every few seconds for the lifetime of the instance: a trivial query, a short timeout, no authentication, and no per-request log entry that would drown the application logs in noise.

**The trade-off, stated plainly.** A health check that depends on the database means that when the database fails, *every* instance reports unhealthy simultaneously. The load balancer then removes every target and serves 503s for all traffic — including requests that never needed the database. Worse, an Auto Scaling group or ECS service reading those same failed checks may begin terminating and replacing instances, and each replacement immediately opens fresh connections to a database that is already struggling. A brief database interruption can escalate into a longer outage that the recovery machinery itself prolongs.

The industry response is to separate the two questions:

- **Liveness** — "is this process alive and not deadlocked?" Shallow, checks no dependencies, and answers whether the instance should be *restarted*.
- **Readiness** — "can this instance serve real traffic right now?" Checks dependencies, and answers whether traffic should be *routed* to it.

Kubernetes exposes these as distinct probes. An ALB target group has a single health check, so NovaTech must choose. **The first version uses a single database-aware check** on the grounds that an instance which cannot reach the database cannot serve any meaningful request, so routing traffic to it produces confusing errors rather than useful service. If cascading-failure behaviour proves to be a problem in practice, the design will split into `/health/live` and `/health/ready`.

---

## 6. Configuration

All environment-specific values are supplied through environment variables rather than hardcoded, so the same application artifact runs unchanged in every environment:

| Variable            | Purpose                                                    |
|---------------------|------------------------------------------------------------|
| `APP_ENV`           | development, staging, or production                        |
| `API_PORT`          | Port the application listens on                            |
| `LOG_LEVEL`         | Logging verbosity (e.g. DEBUG locally, INFO in production) |
| `DATABASE_HOST`     | Database hostname                                          |
| `DATABASE_PORT`     | Database port                                              |
| `DATABASE_NAME`     | Database name                                              |
| `DATABASE_USER`     | Database username                                          |
| `DATABASE_PASSWORD` | Database password                                          |
| `SECRET_KEY`        | JWT signing secret                                         |
| `JWT_EXPIRATION`    | Token lifetime (60 minutes)                                |

Local development and AWS supply different values for these settings. Locally the database host is `localhost`; in AWS it is an Amazon RDS endpoint. **The application code does not change between environments** — only its configuration does. This property is what makes the migration tractable at all.

**Secrets versus configuration.** `DATABASE_PASSWORD` and `SECRET_KEY` are secrets, not ordinary settings. They are never committed to Git in any form. Locally they live in a `.env` file that is listed in `.gitignore`; in AWS they will be stored in AWS Secrets Manager and injected at runtime. Ordinary configuration such as `APP_ENV` or `LOG_LEVEL` carries no such restriction.

---

## 7. Scope Boundaries

The first version deliberately excludes:

- Payments
- Customer accounts (customers are recorded as a name on an order)
- Product categories
- Product images
- Notifications
- Reporting dashboards
- Multiple products per order
- Advanced roles and permissions
- Refresh tokens and token revocation

These are omitted to keep application complexity low. The subject of this project is migration and infrastructure, and every additional feature is one more thing that must be built, tested, containerized, migrated, and validated.

---

## Summary

The initial NovaTech application consists of three tables — `users`, `products`, and `orders`. It uses stateless JWT authentication so the application can scale horizontally behind a load balancer, snapshots `unit_price` so historical orders never change value, soft-deletes products so order history is never orphaned, decrements inventory atomically so stock counts cannot silently diverge from reality, and exposes a database-aware `/health` endpoint so the load balancer can route traffic only to instances capable of serving it.

The design is intentionally small so the application can be developed locally, containerized, and then migrated to a multi-instance AWS architecture without unnecessary complexity — and so that every architectural decision in it can be explained and defended.
