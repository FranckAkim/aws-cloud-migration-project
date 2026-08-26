# Study Guide 02 — The Application, the Database, and Containers

**Covers:** connection pooling, health checks, transactions and race conditions, SQL injection, schema as code, Docker images and layers, volumes, container networking, Docker Compose
**Project phases:** 2 and 3
**State at time of writing:** NovaTech's API and PostgreSQL both run as containers, started together by Compose on a shared network, with the API gated on the database being healthy. Products and orders endpoints work against real data. No AWS resources yet.

---

## Build steps, in order

What was actually done in these phases, condensed to the steps that matter. Each is followed by the check that proves it worked — a step you haven't verified is a step you haven't finished.

**Database in a container**

1. `docker run` Postgres with `-e POSTGRES_USER/DB/PASSWORD`, `-p 127.0.0.1:5434:5432`, `-d`. *Verify:* `docker ps`, then `docker exec <db> pg_isready -U novatech`.
2. Create a table, delete the container, recreate it — **the data is gone**. *This failure is the point.*
3. Re-run with `-v novatech-db-data:/var/lib/postgresql/data` and repeat the destroy/recreate cycle. *Verify:* the table survives. *Verify the mount itself:* `docker inspect <db> --format '{{json .Mounts}}'`.
4. `docker update --restart unless-stopped <db>` so it returns after a reboot.

**Schema as code**

5. Write `application/database/01-schema.sql` — three tables with `NOT NULL`, `UNIQUE`, `CHECK`, foreign keys `ON DELETE RESTRICT`, `TIMESTAMPTZ`, and a `status` default plus `CHECK`.
6. Remove the container **and the volume** (the init hook only runs when the data directory is empty), then re-run with a second mount: `-v "$(pwd)/application/database:/docker-entrypoint-initdb.d:ro"`.
7. *Verify in this order:* `docker exec <db> ls -la /docker-entrypoint-initdb.d` (the container sees the file), `docker logs <db> | grep 01-schema` (it *ran*, rather than "ignoring"), `\dt` (three tables), `\d orders` (foreign keys present).
8. *Verify the constraints bite:* deliberately insert a negative price, a nonexistent foreign key, and a duplicate email. All three must be rejected, and each error names the constraint it violated.

**Connect the application**

9. `pip install "psycopg[binary,pool]"` → `pip freeze > requirements.txt`.
10. Add `DATABASE_*` and `DB_POOL_*` to `config.py`; `database_password: SecretStr` with **no default**.
11. Create `db.py`: a `ConnectionPool` with `open=False` and `connect_timeout=3`, plus a `check_database()` that returns a boolean and never raises.
12. Rewrite `main.py` around a **lifespan handler** — open the pool at startup, close it at shutdown, log once per worker with the PID. `/health` runs the check and returns 200 or **503**.
13. Add the `DATABASE_*` entries to `.env`; at this stage `DATABASE_PORT=5434`, the *host* mapping.
14. *Verify by breaking it:* `docker stop <db>` → 503 and `"database":"down"`, app still running. `docker start <db>` → 200 again **without restarting the app**.

**Endpoints**

15. `GET /api/products` and `/api/products/{id}` — `row_factory=dict_row`, **parameterised** queries, `WHERE is_active = TRUE`, 404 when absent.
16. `POST /api/orders` — inside one `with pool.connection()` transaction: read the price, `UPDATE ... WHERE quantity >= %s`, check `rowcount == 0`, then insert with `RETURNING`. Map exceptions to **404** and **409**. Validate the body with a Pydantic model.
17. *Verify:* record stock **before**. Create an order → 201, stock drops. Over-order → **409**, stock unchanged, **no order row** (the rollback). Bad id → 404. `quantity: 0` → 422.

**Containerise**

18. Write `.dockerignore` first — `.venv/`, `.git/`, `__pycache__/`, and **`.env`**, because a secret in an image layer is permanent.
19. Write the `Dockerfile`: slim base, `PYTHONUNBUFFERED=1`, `COPY requirements.txt` → `pip install` → **then** `COPY` source, non-root user, `CMD` in exec form.
20. `docker build -t novatech-api:0.1.0 .` *Verify caching:* build twice (all `CACHED`), edit a source file (pip still cached), `touch requirements.txt` (pip re-runs).
21. Run the container standalone with `--env-file` — **it cannot reach the database.** *This failure is also the point:* `localhost` inside a container is that container.

**Compose**

22. `docker rm -f` both containers; the volume keeps the data.
23. Create a root `.env` and `.env.example` for Compose variable substitution.
24. Write `docker-compose.yml`: `db` with a `pg_isready` **healthcheck**; `api` with `build: .`, `DATABASE_HOST: db`, `DATABASE_PORT: 5432`, and `depends_on: condition: service_healthy`; the volume declared `external: true` so existing data is reused.
25. `docker compose config` to validate and inspect resolved values **before** running anything.
26. `docker compose up -d`. *Verify:* `docker compose ps` shows db `healthy`, and the startup log now reads **`db=db:5432`** with **no connection-retry warnings**.
27. Add a `healthcheck` to `api` as well — using Python's `urllib`, since the slim image has no `curl` — with `start_period` so a slow boot isn't counted as failure.
28. Commit and **push** after each working milestone, running `git status` first and confirming no `.env` appears.

---

# 1. The application and data layer

## 1.1 Connection pooling

Opening a database connection is expensive: a TCP handshake, authentication, and — in PostgreSQL — **a new server-side process forked per connection**. Doing that per request would dominate latency.

A **pool** opens a small number of connections up front and lends them out. `with pool.connection() as conn:` borrows one and returns it automatically, even if an exception is raised. Without that guarantee, connections leak until the pool is exhausted and the application hangs.

**Sizing is the interesting part.** PostgreSQL's default `max_connections` is 100 — for the entire server, not per client. So:

```
instances × pool_max ≤ max_connections − headroom
```

Six instances with a pool of 20 is 120 connections against a limit of 100: new instances fail to connect exactly when traffic is highest. NovaTech uses `max_size = 5`, deliberately conservative. Small RDS instance classes allow far fewer than 100, so this must be re-checked against the chosen instance size.

**Timeouts are not optional.** `connect_timeout=3` on the connection and `timeout=2` when borrowing from the pool. Without them, a health check against an unreachable database *hangs* rather than failing — and a hung check is worse than a failed one, because the caller learns nothing until its own timeout fires.

## 1.2 Fail fast, or stay up and report?

Two opposite behaviours, and choosing correctly depends on whether the problem can fix itself.

| Situation | Behaviour | Why |
| --- | --- | --- |
| `SECRET_KEY` missing or too short | **Refuse to start** | Permanent misconfiguration; an operator must fix it. Starting up "successfully" while insecure is the dangerous outcome. |
| Database unreachable | **Start, report unhealthy, retry** | Usually transient. A crash loop can't even serve `/health` to explain itself, and the container disappears before anyone can inspect it. |

**Fail fast on what won't fix itself.** Everything else should stay alive, stay observable, and recover on its own.

The retry behaviour that makes the second row work is **exponential backoff** — 1s, 2s, 4s, 8s, 16s, 32s, 60s — so a struggling dependency isn't hammered while it recovers.

## 1.3 Liveness and readiness

- **Liveness** — "is this process alive and not wedged?" Shallow, checks no dependencies. Answers: *should this be restarted?*
- **Readiness** — "can this serve real traffic right now?" Checks dependencies. Answers: *should traffic be routed here?*

Who consumes them in the target architecture:

| Watcher | Reads | Decides |
| --- | --- | --- |
| Application Load Balancer | `/health` on each target | Route traffic here, or take it out of rotation |
| ECS / Auto Scaling | Container or instance health | Restart / replace the task or instance |
| Docker Compose (locally) | `healthcheck` block | Whether dependents may start |

NovaTech's `/health` performs a real `SELECT 1`, returning **200** with `"database":"up"` or **503** with `"database":"down"`. Status code for the machine, body for the human.

**The documented trade-off:** a database-dependent check means a database outage marks *every* instance unhealthy simultaneously, so the load balancer has nothing to route to — and ECS may begin replacing tasks, each new one connecting to an already-struggling database. A brief blip becomes a long outage that the recovery machinery prolongs. Splitting `/health/live` from `/health/ready` avoids this; a single ALB health check forces a choice.

## 1.4 Transactions, atomicity, and the race for the last unit

Creating an order is two writes — insert the order, decrement stock — that must both happen or neither.

**Atomicity.** In psycopg, `with pool.connection() as conn:` *is* the transaction boundary: it commits when the block exits normally and **rolls back if any exception escapes**. So raising `InsufficientStock` after a `SELECT` leaves no trace at all.

**The race.** Two customers order the last unit simultaneously. The fix is to make the check and the write one statement:

```sql
UPDATE products
SET quantity = quantity - :n
WHERE id = :id AND quantity >= :n
```

Transaction A takes an **exclusive row lock**, evaluates the condition against committed data, writes, and holds the lock until commit. Transaction B **blocks**; when A commits, B re-reads the latest committed row, re-evaluates its own `WHERE`, finds it false, and updates **zero rows**. `cur.rowcount == 0` is how the application learns it lost.

**The general principle: TOCTOU** — time-of-check to time-of-use. A `SELECT` followed by a separate `UPDATE` leaves a window in which state can change. Collapsing them removes the window.

Alternatives worth naming: **pessimistic locking** (`SELECT ... FOR UPDATE` — lock on read) and **optimistic locking** (a version column, retry on conflict — better under low contention because nothing blocks).

**Why this matters more after migrating:** one on-prem server made simultaneous orders rare. Several instances behind a load balancer make them routine. Correctness that was accidental must become explicit.

**Beyond the database:** when a step happens in an external system that can't be rolled back, the tools are **idempotency keys** (so a retry doesn't duplicate), **retries with backoff**, and **compensating actions** (a second operation that undoes the first).

## 1.5 SQL injection

Never build SQL by concatenating input:

```python
cur.execute("SELECT * FROM products WHERE sku = '" + sku + "'")   # NEVER
```

A SKU of `x'; DROP TABLE orders; --` becomes a valid instruction to destroy data. The database cannot distinguish the parts you meant as code from the parts a stranger supplied.

**Parameterised queries** send the statement and the values separately:

```python
cur.execute("SELECT * FROM products WHERE sku = %s", (sku,))
```

The `%s` is *not* string formatting. The value is treated strictly as data, so a malicious SKU becomes a harmless search for a product that doesn't exist.

**Rule with no exceptions:** user input is never concatenated into SQL — not with `+`, f-strings, or `.format()`.

*(Python detail: `(x,)` is a one-element tuple; `(x)` is just `x`. Dropping the comma is a classic bug.)*

## 1.6 Data-layer details worth remembering

**Sequence gaps are normal.** A failed insert still consumes its `SERIAL` value, because sequences are non-transactional — rolling them back would require locking and serialise every insert. So IDs have gaps, are not contiguous, and must never be assumed or hardcoded. Reference rows by natural key (SKU, email) in scripts and fixtures.

**Statement-level atomicity.** A multi-row `INSERT` is one statement: if one row violates a constraint, **all** rows are rejected.

**Money.** Use `NUMERIC(10,2)`, never a float — binary floating point can't represent 0.10 exactly. But JSON has no decimal type, so `39.00` serialises as `39.0`. Financial APIs often return amounts as strings or integer cents for this reason.

**Timestamps.** `TIMESTAMPTZ`, not `TIMESTAMP`. The former is an absolute moment; the latter is a wall-clock reading with no indication of where it was taken. Servers and logs run on UTC.

**Soft delete costs vigilance.** Every product query needs `WHERE is_active = TRUE`. Forget it once and retired products leak back into the application. A repeated rule is a signal it belongs somewhere central — a view or a shared query path.

**Constraints belong in the database.** `NOT NULL`, `UNIQUE`, `CHECK`, and foreign keys are enforced no matter which application, script, or person connects. `ON DELETE RESTRICT` turns a soft-delete *policy* into something the database *guarantees*.

**Validate at the edge too.** Pydantic rejects `quantity: 0` before any code runs. Both layers deliberately: the API refuses politely with a helpful message; the database refuses absolutely. Defense in depth.

## 1.7 HTTP status codes, used precisely

| Code | Meaning | Example here |
| --- | --- | --- |
| 200 | OK | Product returned |
| 201 | Created | Order created — a new resource exists |
| 404 | Not found | Well-formed request, no such product |
| 409 | Conflict | Valid request, current state forbids it — insufficient stock |
| 422 | Unprocessable | Request itself invalid — `quantity: 0`, `product_id: abc` |
| 503 | Service unavailable | Alive but not ready — database down |

Vague codes cost real time in production, because whoever is debugging has to guess which category of problem they're in.

## 1.8 Schema as code

A schema that exists only inside a running database has NovaTech's on-prem problem: it's the accumulated result of commands somebody typed, and nobody can rebuild it confidently.

**Initialization scripts** — the Postgres image runs `.sql` and `.sh` files from `/docker-entrypoint-initdb.d/` in alphabetical order (hence `01-`, `02-`), **but only when the data directory is empty.** Perfect locally; useless against a production database that already has data.

**Migrations** (Alembic, Flyway) keep an ordered set of *changes* plus a record of which have been applied, so any database can be brought forward from wherever it is. That is what a live RDS instance needs, and it's Phase 11's subject.

The pattern, applied a third time: **`requirements.txt` describes an environment, a Dockerfile describes a machine, a schema file describes a database structure.** Preserve the recipe, not the artifact.

---

# 2. Containers

## 2.1 What a container actually is

**Not a virtual machine.** A VM emulates hardware and runs its own kernel. A container is **a process on the host kernel**, isolated by **namespaces** (its own view of filesystem, network, and process table) and constrained by **cgroups** (CPU and memory limits). Hence millisecond startup and small size — and hence containers being a Linux kernel feature, which is why Docker Desktop on Windows runs them inside a Linux VM.

**Image vs container:** an image is an immutable stack of read-only layers; a container is a running instance with a **thin writable layer** on top. One image, many containers.

**`docker exec` doesn't "enter" anything.** It starts a *new process* attached to the same namespaces — same filesystem view, same network, same PID namespace. Anything it changes lives only in that container's writable layer and dies with it. **Use `exec` to inspect, never to repair:** hand-fixing running containers is exactly how on-prem servers became unrebuildable.

**Client and server.** The `docker` command is a client talking to a daemon over a socket; the daemon may be elsewhere. Consequently **access to the Docker socket is effectively root on the host.**

## 2.2 The Dockerfile, line by line

```dockerfile
FROM python:3.14-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY application/backend/ ./
RUN useradd --create-home appuser && chown -R appuser:appuser /app
USER appuser
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**`slim`** — Debian without build toolchains: ~50 MB versus ~350 MB. `alpine` is smaller but uses musl instead of glibc, so many Python packages have no prebuilt wheel and must compile — slower builds, occasional breakage.

**`PYTHONUNBUFFERED=1`** — without it, Python buffers stdout when it isn't a terminal and `docker logs` shows nothing. Every containerised Python app needs this.

**`USER appuser`** — **containers run as root by default.** An exploited application then has root inside the container, a far better position from which to attempt escaping to the host. Running as non-root is a standard finding in image scanners.

**`EXPOSE`** is documentation only. `-p` does the actual publishing.

**`CMD` in exec form** (a JSON array) makes the process PID 1 and lets it receive shutdown signals properly. No `--reload`: a development convenience that would be a liability in production.

**Fixed internal port.** Inside its own network namespace the app has no competition for port 8000; the *external* port is a mapping concern.

## 2.3 Layer caching — the highest-value Dockerfile skill

Each instruction creates a layer. On rebuild, Docker reuses cached layers until one whose inputs changed — **and every layer after that rebuilds**, whether or not its own inputs changed. The cache breaks forward, never backward.

Therefore: **expensive and rarely-changing goes early; cheap and frequently-changing goes late.** Copying `requirements.txt` and installing *before* copying source means a code change doesn't reinstall dependencies.

Demonstrated in four builds:

| Build | Action | Result |
| --- | --- | --- |
| 1 | Cold | Everything runs |
| 2 | Nothing changed | All `CACHED`, ~1.1s |
| 3 | Edit `main.py` | `pip install` **CACHED**; rebuild from `COPY application/backend/` |
| 4 | `touch requirements.txt` | `pip install` re-runs, and everything after it |

Build 4 is what would happen on **every code change** with the naive `COPY . .` before `RUN pip install`.

**Applying the principle:** a large ML model download belongs early, near the dependency install — or in a purpose-built base image, or fetched at runtime from S3 if it changes on a different schedule than the code. The trade-off is image size and deployment transfer time versus cold-start time and a runtime dependency.

*Debugging note:* the build cache is not flaky. When a layer rebuilds unexpectedly, **something really did change** — check the reported build-context size. Editor autosaves count.

## 2.4 Build context and `.dockerignore`

`docker build .` packages the entire directory and sends it to the daemon. `.dockerignore` excludes files from that context — `.venv/`, `.git/`, `__pycache__/`.

**And one entry is a security control:** **`.env` must never enter the image.** A copied file becomes a permanent, readable layer; anyone who can pull the image can extract it. Secrets are supplied at **runtime**, never at build time.

## 2.5 Volumes and the stateless/stateful divide

The container's writable layer dies with the container — proven by creating a table, deleting the container, and finding the data gone. A **volume** is storage Docker manages outside the container lifecycle:

```
-v novatech-db-data:/var/lib/postgresql/data
```

Same left-to-right logic as `-p`: outside on the left.

This is the divide the whole target architecture rests on:

- **Application containers are stateless** — kill one, start three, replace them all during a deploy; nothing is lost. This is why stateless JWTs were chosen.
- **Databases are stateful** — and running one yourself means owning storage durability, backups, tested restores, failover, patching, and replication.

**That is the argument for RDS**, reached from first principles rather than accepted from a tutorial.

*Postgres image detail:* `POSTGRES_USER`/`DB`/`PASSWORD` apply **only on first initialization**. Changing them later has no effect on an existing data directory — and neither do new init scripts.

## 2.6 Container networking — the lesson that cost the most time

**Every container has its own network namespace, including its own loopback.** Code inside a container connecting to `127.0.0.1` reaches *that container* and nothing else.

NovaTech's API, containerised with `DATABASE_HOST=localhost`, could not reach a database that was running perfectly — because Postgres was in a different namespace. The error was **"connection refused"**: something answered, and the answer was no.

**Refused versus timeout is a diagnosis, not a detail:**

| Symptom | Means | In AWS |
| --- | --- | --- |
| Connection refused | Nothing is listening there | App not started, wrong port |
| Timeout | Packets are being silently dropped | Security group / NACL / routing |

A further consequence: because the database's port was published as `127.0.0.1:5434`, it listened only on the *host's* loopback — so even reaching the host's bridge address would have been refused. Security decisions have reach.

**The fix: a user-defined network and DNS.** Containers on one resolve each other **by name** through Docker's embedded DNS. The app connects to `db:5432` — the container's own port, not the host mapping, because the traffic never touches the host.

This is the same shape as the target architecture: the app resolves an RDS endpoint by name and connects on 5432, with no port mapping anywhere. `DATABASE_HOST` goes `localhost` → `db` → an RDS hostname. **Configuration, not code.**

## 2.7 Docker Compose

```yaml
services:
  db:
    image: postgres:17
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
    volumes:
      - novatech-db-data:/var/lib/postgresql/data
      - ./application/database:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 3s
      retries: 10

  api:
    build: .
    env_file: [.env]
    environment:
      DATABASE_HOST: db
      DATABASE_PORT: 5432
    depends_on:
      db:
        condition: service_healthy

volumes:
  novatech-db-data:
    external: true
```

**Service names are hostnames.** `db` resolves via Docker's DNS.

**`environment:` overrides `env_file:`** — explicit beats file, the same precedence rule as real environment variables beating `.env`.

**`healthcheck` + `depends_on: condition: service_healthy`** is ordering by *readiness*, not start order. The API container will not start until the database answers `pg_isready`. This is the local equivalent of ALB target health checks, and it's why the API's logs are now free of the connection-retry storm.

**`external: true`** means "use the existing volume" rather than creating a new project-prefixed one — which is what preserved the schema and data.

**Compose namespaces everything by project** (the directory name): `aws-cloud-migration-project-db-1`, network `..._default`, image `..._api`. Several projects coexist on one machine without collision. Inside the network they're still reachable by **service** name.

**Secrets improved, not solved.** The database password moved from a command-line argument (visible in `ps`, shell history, and `docker inspect`) into a gitignored `.env` that Compose reads. Better — but `docker compose config` prints it in plain text, and Compose substitution is convenience, not secrecy. Real secrecy arrives with Secrets Manager in AWS.

*Health check inside a slim image:* there is no `curl`, so the API's check uses Python's `urllib`. `start_period` gives the app time to boot before failures count against it.

---

# 3. Troubleshooting log

| Symptom | Cause | Fix | Principle |
| --- | --- | --- | --- |
| `psql: FATAL: the database system is starting up` | Queried immediately after `docker run -d` | Wait for `pg_isready` | Running ≠ ready |
| Data gone after recreating the container | No volume; writable layer deleted with the container | Named volume | Containers are ephemeral by design |
| Container "not running" on `exec` | It failed to start; `docker ps` hides it | `docker ps -a`, read logs | Created ≠ running |
| `ports are not available: 5432` | Host port already taken | Map `127.0.0.1:5434:5432` | Host ports are a shared finite resource |
| `ignoring /docker-entrypoint-initdb.d/*` | Mounted an empty directory (file was in a different folder) | Move the file; `docker exec ls` to check what the container sees | Inspect inside the container, don't reason about mounts |
| Init script ignored on a second run | Hook runs only when the data directory is empty | Remove the volume | Read the log line; it said so |
| Product id 1 not found after inserting one product | A failed insert consumed the sequence value | Use the returned id, or a natural key | Sequences are non-transactional; gaps are normal |
| Seed INSERT added nothing | One duplicate SKU rejected the whole multi-row statement | Insert only the new rows | Statement-level atomicity |
| App started with an empty `SECRET_KEY` | Required means present, not non-empty | `Field(min_length=16)` | Silent security failures are the dangerous kind |
| `422 json_invalid ... "Extra data"` | A multi-line curl pasted twice put two JSON objects in one body | Single-line command, or `-d @file.json` | Read the parse error's position |
| Container: `connection refused` to `127.0.0.1:5434` | Container's own loopback; the database is elsewhere | Shared network, `DATABASE_HOST=db`, port 5432 | Each container has its own network namespace |
| `curl: (56) Connection reset by peer` right after `compose up` | Curl fired before uvicorn was listening | Wait, or add a health check | Running ≠ ready, one layer up |
| Build cache missing "for no reason" | The source really had changed (editor autosave) | Check the build-context size in the output | Believe the tool; find what changed |
| Health check appeared to do nothing | The `healthcheck` block was indented outside the service | Nest it under the service | In YAML, indentation *is* the structure |
| `docker: name is already in use` | The old container still existed | `docker rm -f <name>` | Container names are unique per host |
| Testing `/health` on the wrong port | Host app on 8000, container on 8080 | Read the URL | Two copies of one app differ only by port |

---

# 4. Interview questions

Cover the answers; say yours out loud first.

**Q: What's the difference between a container and a virtual machine?**
A VM emulates hardware and runs its own kernel, so it's heavy and slow to start. A container is a process on the host kernel isolated by namespaces and limited by cgroups — its own view of the filesystem, network, and process table, but a shared kernel. That's why containers start in milliseconds and are measured in tens of megabytes.

**Q: How do you keep Docker builds fast?**
Order the Dockerfile so expensive, rarely-changing steps come first. Each instruction is a cached layer, and invalidating one invalidates everything after it — so copy the dependency manifest and install *before* copying source. Otherwise every code change reinstalls every dependency. Also keep the build context small with `.dockerignore`.

**Q: Where do secrets go in a containerised app?**
Never into the image — a copied file is a permanent readable layer. Never on the command line — that's visible in `ps` and stored in `docker inspect`. They're injected at runtime as environment variables, sourced from a secrets manager. In AWS, the task definition references a Secrets Manager ARN and the platform resolves it at container start; or the app fetches it via the SDK, which allows re-reading after rotation. Best of all, RDS IAM authentication issues short-lived tokens so no long-lived password exists.

**Q: Your app can't reach its database. Walk me through it.**
Start with the error, because it's already a diagnosis. "Connection refused" means something answered and rejected — nothing listening on that port, wrong port, or the app pointed at itself. A timeout means packets are being silently dropped — a security group, NACL, or routing problem. Then check the obvious layer confusion: inside a container, `localhost` is the container, not the host. Then verify the dependency is actually *ready*, not merely running. Then check that the connection settings point where you think.

**Q: Why not run PostgreSQL in a container in production?**
Because containers are ephemeral and databases aren't. You can attach a volume, but then you own storage durability, backups, tested restores, failover when the host dies, patching, and replication — the operational burden RDS exists to absorb. Application containers are stateless and disposable, which is what makes them safe to kill and replace; a database is neither.

**Q: How do containers find each other?**
On a user-defined network, by service name, through the container runtime's embedded DNS. In Compose, `db` resolves to the database container and you connect on its own port — the host port mapping is irrelevant because the traffic never reaches the host. It's the same model as resolving an RDS endpoint by DNS name in a VPC.

**Q: Two customers order the last item at the same instant.**
The stock check and the decrement are a single conditional `UPDATE` inside a transaction. The first takes an exclusive row lock; the second blocks, then re-evaluates against committed data when the lock releases, matches zero rows, and is rejected. A separate `SELECT` then `UPDATE` leaves a TOCTOU window in which state can change. This matters more after migrating, because multiple instances behind a load balancer make simultaneous requests routine.

**Q: What if a step in that flow can't be rolled back — an external payment, say?**
Transactions only cover the database. For external effects you need idempotency keys so retries don't duplicate, retries with backoff, and compensating actions to undo work already done. And you log the failure and return an error the client can safely retry.

**Q: How do you prevent SQL injection?**
Parameterised queries, always. The statement and the values are sent separately, so the database treats input strictly as data and never as code. No concatenation, no f-strings, no exceptions.

**Q: Should a health check test the database?**
It depends which question it answers. Readiness — should traffic route here — should check dependencies, because an instance that can't reach the database can't serve real requests. Liveness — should this be restarted — shouldn't, because if every instance fails at once the load balancer has nothing to route to and the platform may start replacing tasks that each hammer a recovering database. Ideally two endpoints. Either way it must be cheap, unauthenticated, and excluded from access logs.

**Q: Your app starts before the database is ready. What do you do?**
Two things. The application retries with exponential backoff and reports itself unready rather than crashing, so a blip doesn't become a crash loop. And the platform orders startup by readiness — locally that's Compose's `depends_on: condition: service_healthy`; in AWS it's health checks on the target group and the service.

**Q: How do you size a connection pool?**
From the database's limit backwards. Postgres allows a fixed number of connections server-wide, so multiply pool size by the maximum number of instances and leave headroom for admin access and migrations. Small RDS instance classes allow far fewer than the default 100, so it's a per-environment decision, not a constant.

---

# 5. Command reference

**Docker**

```
docker build -t name:tag .
docker images
docker ps / docker ps -a
docker logs <name> / docker logs --since 2m <name>
docker exec -it <name> <command>
docker inspect <name> --format '{{json .Mounts}}'
docker rm -f <name>
docker update --restart unless-stopped <name>
docker volume ls / docker volume rm <name>
```

**Compose**

```
docker compose config          # validate and show resolved values
docker compose up -d
docker compose ps
docker compose logs api
docker compose down            # stop and remove; volumes survive
docker compose down -v         # ALSO DELETES VOLUMES — destroys data
```

**PostgreSQL**

```
docker exec <db> pg_isready -U <user>
docker exec -it <db> psql -U <user> -d <db>
\dt      list tables
\d <table>   describe, including constraints
\q       quit          \pset pager off
```

**API testing**

```
curl -i http://localhost:8080/health
curl -s http://localhost:8080/api/products | python3 -m json.tool
curl -i -X POST http://localhost:8080/api/orders -H "Content-Type: application/json" -d '{...}'
```

---

## Milestones

- [x] Local application — API, configuration, secrets handling, logging
- [x] PostgreSQL — schema as code, constraints, transactions
- [x] Docker — images, layers, volumes, networking, non-root
- [x] Docker Compose — multi-service stack with health-gated startup
- [ ] Cloud fundamentals
- [ ] AWS core services · IAM · VPC · networking
- [ ] Terraform
- [ ] Migration: assessment, strategy, execution
- [ ] CI/CD, security hardening, monitoring, disaster recovery, cost

**Known gaps, deliberately carried forward:** no authentication yet, so `user_id` is supplied by the client — which means anyone can claim to be anyone. Fixed when JWTs arrive, where identity comes from a verified token and never from the request body. No migrations yet, so schema changes still require destroying the database. Health-check split (liveness vs readiness) not yet implemented.
