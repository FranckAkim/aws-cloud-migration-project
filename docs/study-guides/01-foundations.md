# Study Guide 01 — Foundations

**Covers:** development environment, Git, Linux fundamentals, application design, configuration & secrets, Docker & PostgreSQL
**Project phases:** 0, 1, and the start of 3
**Status at time of writing:** NovaTech API running locally with `/health`; PostgreSQL running in a container with a persistent volume; no AWS resources created yet.

---

## How to use this guide

Section 1 is concepts. Section 2 is the troubleshooting log — every real failure hit during these phases, with symptom, cause, fix, and the underlying principle. Section 3 is interview questions with model answers. Section 4 is a command reference.

Read section 3 by covering the answers first. An answer you can recognize is not an answer you can give.

---

# 1. Concepts

## 1.1 Cloud migration fundamentals

**Why companies migrate.** Not "the cloud is cheaper" — often it isn't. The real drivers:

| Driver | Problem on-prem | What cloud offers |
| --- | --- | --- |
| High availability | A failed server is a **single point of failure** | Redundancy across Availability Zones |
| Scalability | Hardware sized for peak demand, sitting idle | Add capacity on demand |
| **Elasticity** | Cannot shrink | Capacity grows *and shrinks* automatically |
| Disaster recovery | Manual backups, untested restores | Automated backups, snapshots, replication |
| Operational focus | Staff maintain hardware | Staff work on the product |
| Cost model | **CapEx** — large up-front purchases | **OpEx** — pay for what you use |

**Scalability vs elasticity.** Scalability is the *ability* to handle more load by adding resources. Elasticity is that happening **automatically** in response to demand — and shrinking again. On-prem can be scalable; only cloud is genuinely elastic.

**Total Cost of Ownership (TCO).** The counter to "we own our servers outright." Owned hardware still costs electricity, cooling, floor space, staff time, and a full refresh every 3–5 years — after which the company owns obsolete equipment. And it must be sized for peak, so most capacity is idle most of the time.

**Migration risks** (an interviewer will ask): runaway cost if resources aren't governed; downtime and compatibility problems during cutover; **vendor lock-in** as you adopt provider-specific services; and the **skills gap** — misconfiguration by inexperienced staff is a leading cause of real cloud breaches.

---

## 1.2 Environment and tooling

**Shells are not interchangeable.** One Windows machine can host several, and they disagree about basic things:

| Shell | Prompt marker | `D:\` appears as | Has `ss`, `apt` |
| --- | --- | --- | --- |
| PowerShell | `PS C:\...>` | `D:\` | no |
| Git Bash | `MINGW64` | `/d` | no |
| WSL2 Ubuntu | `user@host:/mnt/d$` | `/mnt/d` | yes |

**Read your prompt before you read your command.** Which machine, which shell, which directory, which user. This resolves a large share of "command not found" and "no such file" errors — and matters more once you are SSH'd into remote servers.

**PATH.** When you type a command, the shell searches the directories listed in `PATH` for a matching executable. Not found → `command not found`.

**Environment inheritance — the single most repeated lesson of these phases.** A process receives a **copy** of the environment when it starts. Later changes never reach an already-running process. This one fact explains:

- A new install isn't visible in an already-open terminal (needs a fresh shell).
- `source .venv/bin/activate` affects only the current shell, and must be re-run in every new terminal.
- `source` is used rather than executing the script, because a child process's environment changes die with the child.
- Changing `.env` does nothing until the application restarts.
- In AWS, changing an environment variable on a running service requires a new deployment, not a config save.

**WSL2** runs a real Linux kernel inside Windows. Windows drives appear under `/mnt/`. Docker Desktop runs its engine inside its own hidden `docker-desktop` distro — containers are a Linux kernel feature, so on Windows they always run inside Linux.

**Filesystem choice matters.** Code kept on `/mnt/c` or `/mnt/d` is reached through a translation layer that approximates Unix permissions and symlinks imperfectly, and is significantly slower. On one machine venv creation failed there and worked on the native Linux filesystem. Prefer `~/projects/...` inside WSL; let Git be the bridge. Also keep repositories **out of OneDrive** — the sync client fights Git over lock files and will happily upload a virtual environment.

---

## 1.3 Git and repository hygiene

**The repository is the project.** If it isn't committed *and pushed*, it does not exist for anyone else — including you on another machine. Committing is local; pushing is what publishes.

**Inspect before you act.** `git fetch` updates your knowledge of the remote without touching your working tree. `git pull` is fetch **plus** an automatic merge. Fetch, read `git status`, then decide.

Reading `git status` after a fetch:

- *ahead of origin/main* — you have unpushed commits. `git push`.
- *behind* — the remote has commits you lack. `git pull`.
- *diverged* — both sides have unique commits. Requires a merge.

**What belongs in Git, and the principle behind it: preserve the recipe, not the artifact.**

| Committed | Not committed |
| --- | --- |
| `requirements.txt` (pinned versions) | `.venv/` (machine-specific, rebuildable) |
| `.env.example` (keys, no values) | `.env` (real secrets) |
| Source code, docs, `.gitignore`, `.gitattributes` | `__pycache__/`, build output |

`.gitignore` must exist **before** the first commit that could sweep up a secret. Removing a secret from Git history is painful, and the credential must be treated as compromised and rotated regardless.

**`.env.example` is not bureaucracy.** It documents which variables an application requires, so a fresh clone on another machine can be configured without guesswork and without a secret ever being exposed.

**Line endings.** Unix ends lines with `LF`, Windows with `CRLF`. Git for Windows converts on checkout/commit by default; Linux Git does not. Sharing one working tree between both produces diffs where *every line* changed and the text looks identical. The fix belongs in the repo, not on each machine — `.gitattributes` containing `* text=auto eol=lf` travels with the clone. Beyond cosmetics: a shell script saved with CRLF fails inside a Linux container with `/bin/bash^M: bad interpreter: No such file or directory`.

**Commit messages** say what and why. They are read far more often than written.

---

## 1.4 Linux fundamentals

**Permissions.** `ls -la` output, decoded:

```
-rw-r--r--  1 franc franc  3771 May 29 19:54 .bashrc
│└┬┘└┬┘└┬┘    └─┬─┘ └─┬─┘
│ │  │  │       │     └── owning group
│ │  │  │       └──────── owning user
│ │  │  └──────────────── permissions for everyone else
│ │  └─────────────────── permissions for the group
│ └────────────────────── permissions for the owner
└──────────────────────── type: - file, d directory
```

`r` read, `w` write, `x` execute. **On a directory the meanings differ:** `r` lists the contents, `x` permits entering/traversing it. A directory with `r` but no `x` is nearly useless.

Files beginning with a dot are hidden by convention and are usually configuration. `.` is the current directory, `..` the parent. `.bash_history` is owner-only (`-rw-------`) because shell history routinely contains sensitive material.

**Root and package management.** `apt` writes to `/var/lib/dpkg`, `/usr/lib`, `/etc` — root-owned, hence `sudo`. `apt update` refreshes the package catalogue; `apt upgrade` installs newer versions. Reading the menu versus ordering the food. Ubuntu **phases** some updates, rolling them out to a fraction of machines first — the same idea as a **canary deployment** in CI/CD.

**Locks.** `apt` failed with `Could not open lock file /var/lib/dpkg/lock-frontend`. A lock serializes access to shared mutable state so two processes cannot corrupt it. The same concept appears three times in this project: the dpkg lock, the database row lock preventing an oversell, and Terraform state locking preventing two engineers applying at once.

**Processes and ports.** `ps aux` lists processes; the `COMMAND` column shows the **full command line including arguments**, visible to every user on the machine. `ss -tulpn` lists listening sockets (`sudo` needed to see process names).

**Bind addresses — one of the most important ideas in the project.**

- `127.0.0.1` — loopback only; reachable solely from the same machine.
- `0.0.0.0` — every interface the machine has.

`0.0.0.0` means *listen everywhere*, **not** *publicly accessible*. Reachability is decided by network topology and firewalls. In production an application must bind `0.0.0.0` so the load balancer can reach it; exposure is then controlled by private subnets and security groups.

Distinguish it from `0.0.0.0/0` in a **firewall rule**, which does mean "from anywhere on the internet" and is dangerous on sensitive services.

**Foreground processes own the terminal.** Stopping one to get your prompt back kills the service. Real servers run applications as **daemons under systemd** — detached from any terminal, started at boot, restarted on crash — or as containers.

**Shell mechanics.** `|` pipes one command's output into another. Each command returns an **exit code** (`0` = success, visible via `echo $?`). Commands separated by newlines run regardless of whether the previous one failed; **`&&` runs the next command only on success**. This is exactly the difference between a CI/CD pipeline that halts on a failed test and one that deploys a broken build.

**Time.** Servers and logs use **UTC**. Comparing a UTC log line to a local-time event has misdiagnosed many incidents.

---

## 1.5 Application design decisions (NovaTech)

The application: three tables — `users`, `products`, `orders` — with JWT auth, deliberately small so the project's subject stays migration rather than features.

**Snapshot transactional facts.** `orders.unit_price` stores the price at the moment of purchase. Referencing the product's current price would make historical order values change retroactively when prices change. A transactional record captures facts as they were.

**Soft delete.** `DELETE /api/products/:id` sets `is_active = false` rather than removing the row, because orders reference products and order history must survive. The foreign key constraint remains as the database-level enforcement; soft delete is the application-level policy. The cost: every product query must filter `is_active = true`, and a soft-deleted row keeps its unique SKU forever.

**Stateless authentication.** Multiple application instances sit behind a load balancer, so a request can land on any of them. Three options:

| Approach | How it works | Trade-off |
| --- | --- | --- |
| In-memory sessions | State in one instance | Breaks entirely behind a load balancer |
| Sticky sessions | LB pins a user to one instance | Breaks when that instance dies; uneven load |
| Shared session store | Redis/DB holds sessions | Correct, but another component to run and secure |
| **Stateless JWT** | Token carries signed identity | **Chosen** — any instance can verify it |

**The JWT trade-off, stated plainly:** because verification needs no shared state, a token **cannot be revoked before it expires**. A stolen token stays valid; a terminated employee keeps access until expiry; logout is client-side only. Mitigated by short lifetimes (60 minutes). A revocation denylist would fix it but reintroduces the shared state JWTs were chosen to avoid. Rotating the signing secret invalidates everyone at once — blunt but effective.

**Atomicity and race conditions.** Creating an order is two writes: insert the order, decrement stock. They run in **one transaction** — both commit or neither does. Otherwise a crash between them silently sells inventory the system still believes it holds.

Concurrency is the harder half. Two customers ordering the last unit:

```sql
UPDATE products SET quantity = quantity - :n WHERE id = :id AND quantity >= :n
```

Transaction A takes an **exclusive row lock**, evaluates the condition against committed data, writes, and holds the lock until commit. Transaction B **blocks**. When A commits, B re-reads the latest committed row and re-evaluates its own `WHERE` clause — now false — so it updates **zero rows** and the order is rejected.

The general principle: a `SELECT` then a separate `UPDATE` leaves a window between checking and acting, during which state can change. This is **TOCTOU** — time-of-check to time-of-use. Collapsing check and write into a single conditional statement removes the window. Alternatives: **pessimistic locking** (`SELECT ... FOR UPDATE`) and **optimistic locking** (a version column with retry).

This matters more *after* migration: one on-prem server made concurrency rare; several instances behind a load balancer make it routine. Correctness that was accidental must become explicit.

**Health checks.** `/health` returns 200 when the process is alive **and** the database is reachable, so the load balancer stops routing to an instance that cannot serve. It must be cheap (`SELECT 1`, short timeout), unauthenticated, and not logged per request — the load balancer calls it every few seconds forever, and those log lines cost real money at scale.

The documented trade-off: a database-dependent check means a database outage marks **every** instance unhealthy at once, so the load balancer serves 503s for everything — and an Auto Scaling group or ECS service may start terminating and replacing instances, each new one hammering the recovering database. A brief blip becomes a long outage that the recovery machinery prolongs. The industry answer separates:

- **Liveness** — is this process alive? Shallow, no dependencies. Decides whether to **restart**.
- **Readiness** — can it serve traffic now? Checks dependencies. Decides whether to **route**.

**Data types.** Money uses `NUMERIC(10,2)`, never a float — binary floating point cannot represent 0.10 exactly and cents drift. Constraints (`NOT NULL`, `UNIQUE`, foreign keys) belong in the database, which enforces them regardless of which application or script connects.

---

## 1.6 Configuration and secrets

**The twelve-factor principle:** strictly separate configuration from code and store configuration in the environment.

The test: **could this repository be made public right now without leaking anything?**

The payoff: **one build artifact runs in every environment.** The image tested in staging is byte-identical to the one in production; only the environment differs. Configuration baked into the repo would mean a different artifact per environment — meaning production runs something never tested.

Config *does* vary between environments; code does not. `DATABASE_HOST` moves from `localhost` to an RDS endpoint with no code change. That property is what makes migration tractable.

**Precedence.** Real environment variables win over the `.env` file. Locally the file supplies values; in AWS the platform injects them and no `.env` exists.

**Branching on environment.** Branching *operational* behaviour (auto-reload, log level, debug output) on `APP_ENV` is normal. Branching *business logic* is dangerous, because production then runs paths nothing else exercised.

**Fail fast.** Settings with no safe default should have **no default at all**, so the application refuses to start when they are missing:

- `api_port`, `log_level` — a wrong value is harmless; defaults are fine.
- `secret_key` — there is no safe value. A default would mean every deployment that forgot to set it shares one publicly-known signing key, and the application would run perfectly while being completely insecure.

**Rule: default the harmless, require the dangerous.**

**Present is not valid.** A required field is satisfied by an empty string. `SECRET_KEY=` passed validation and the app started with an empty signing key — a silent failure, the worst kind. Constraints, not just types: `Field(min_length=16)`.

**Typed settings** convert and validate: `API_PORT=banana` fails at startup with a clear message instead of breaking later. Good validation reports **all** errors in one pass, not just the first.

**Secrets must be hard to print by accident.** A validation error printed the loaded configuration values into the traceback — and tracebacks go to stdout, stdout to container logs, logs to CloudWatch, where many people can read them. `SecretStr` renders as `**********` everywhere and requires an explicit `.get_secret_value()` call, making reading a secret a conscious act.

**Where a secret must never appear:** in Git; as a command-line argument (visible in `ps`, `/proc`, and shell history); in application logs; baked into a container image layer. Log that a secret is *set*, never its value.

**In AWS**, two mechanisms: the platform **injects** the secret from Secrets Manager as an environment variable (simple, portable, but fixed for the container's life — rotation needs a restart), or the application **fetches** it via the SDK at runtime (can re-read after rotation). Best of all, **RDS IAM authentication** issues short-lived tokens from the instance's role, so a long-lived password never exists.

**Version identity.** `/health` should report the build's immutable identity — the Git commit SHA, injected at build time and matching the image tag — not a hand-maintained string that someone must remember to update and therefore won't.

---

## 1.7 Docker and containers

**A container is not a virtual machine.** A VM emulates hardware and runs its own kernel. A container is **a process on the host kernel, isolated by namespaces** (its own view of filesystem, network, PID table) and limited by **cgroups**. Hence millisecond startup, and hence containers being fundamentally a Linux feature.

**Image vs container.** An image is an immutable stack of read-only layers. A container is a running instance with a **thin writable layer** on top. One image, many containers.

Pulling shows the layers individually; layers are shared and cached between images. A tag like `postgres:17` moves as patches release; a **digest** (`postgres@sha256:...`) is exact. Pinning is the same instinct as pinning `requirements.txt`.

**Why this matters for migration.** On-prem servers accumulate undocumented state — packages installed by hand, config edited during an incident — and nobody can rebuild them. A container is defined entirely by a file you can read and rebuild identically. Containerizing is often the highest-value step in a migration regardless of destination.

**Client and server.** The `docker` command is a client talking to the Docker daemon over a socket; the daemon may be elsewhere. Consequently **access to the Docker socket is effectively root on the host** — anyone who can reach it can run a privileged container that mounts the host filesystem.

**Common flags.**

| Flag | Meaning |
| --- | --- |
| `--name` | Human-readable container name; must be unique on the host |
| `-e KEY=value` | Environment variable — how well-built images are configured |
| `-p HOST:CONTAINER` | Port mapping; **outside on the left**. Defaults to all host interfaces — prefix `127.0.0.1:` to restrict |
| `-v NAME:/path` | Mount a volume; **outside on the left** |
| `-d` | Detached — don't hold the terminal |

`docker ps` shows running containers only; **`docker ps -a` shows all**, including ones that failed to start.

**`docker exec -it`** starts a *new process* attached to the same namespaces as the container's existing processes — same filesystem view, same network, same PID namespace. It does not "enter a box"; there is no box.

Anything changed via `exec` lives only in that container's writable layer and vanishes with it. **Containers are cattle, not pets:** use `exec` to inspect, never to repair. Repairing running containers by hand is precisely how on-prem servers became unrebuildable.

**Volumes.** The writable layer dies with the container — proven by creating a table, deleting the container, and finding the data gone. A **volume** is storage Docker manages outside the container lifecycle; mount it at the data path and the data survives destruction and recreation.

This is the **stateless vs stateful** divide the whole target architecture rests on. Application containers hold no data, so they can be killed, replaced, and scaled freely. A database is stateful — and running it yourself means owning storage durability, backups, restore procedures, failover, patching, and replication. **That is the argument for RDS**, reached from first principles rather than accepted from a tutorial.

**Running is not ready.** `docker run -d` returns immediately; Postgres answered `FATAL: the database system is starting up`. A dependency being started is not a dependency being usable. Hence `HEALTHCHECK`, Compose's wait-for-healthy, ALB target health checks, and applications that **retry with backoff** instead of dying at startup.

**Ports are host-wide.** Only one process can hold a host port. A collision on 5432 was resolved by mapping `127.0.0.1:5434:5432` — different outside, unchanged inside.

**Postgres image details worth knowing.** `POSTGRES_USER`/`DB`/`PASSWORD` apply **only on first initialization**; changing them later has no effect on an existing data directory. `/docker-entrypoint-initdb.d/` runs `.sql` and `.sh` files on first initialization — the reproducible way to create a schema. The image enables `trust` authentication for local connections, so `psql` inside the container needs no password: "it has a password" and "the password is required" are different claims.

**psql basics.** SQL statements end with `;` — the prompt changes from `=#` to `-#` while one is unfinished. Backslash commands (`\dt`, `\q`, `\pset`) are psql's own, not SQL. Output pipes through the `less` pager; `q` exits.

---

# 2. Troubleshooting log

Every real failure from these phases. The pattern to internalize: **read the whole error, form a hypothesis, isolate one variable, verify with evidence.**

| Symptom | Cause | Fix | Principle |
| --- | --- | --- | --- |
| `terraform: command not found` after installing | Shell loaded PATH before the install | Open a new terminal | Processes inherit the environment at start |
| `cd /mnt/d/...: No such file or directory` | In Git Bash, where `D:` is `/d` | Enter WSL first | Read the prompt before the command |
| `ss: command not found` | Git Bash, not Linux | Enter WSL | Same |
| `sudo: Authentication failed` | Forgotten WSL password | `wsl -d Ubuntu -u root`, then `passwd franc` | Also proves WSL is a convenience boundary, not a security boundary |
| `apt install` → `Could not open lock file` | Missing `sudo` | Read the whole error — it said so | Locks serialize access to shared state |
| Package count unchanged after "upgrading" | Ran `apt update` twice, never `upgrade` | Run `apt upgrade` | Read output for meaning, not activity |
| `ensurepip is not available` | `python3-venv` not installed | `sudo apt install python3.14-venv` | The error names the package |
| Same error with the package already installed | venv creation on `/mnt/c` | Move the repo to the Linux filesystem | **Isolate the variable** — `/tmp` worked, so the filesystem was at fault |
| `pip: command not found` in a new terminal | venv not activated in that shell | `source .venv/bin/activate` | Activation is per-shell |
| Commands after a failure ran anyway | Newline-separated commands ignore failures | Chain with `&&` | Exit codes matter |
| Every line of an untouched file shows as modified | CRLF working tree vs LF index, two Git installs | `.gitattributes` with `* text=auto eol=lf` | Put the fix in the repo |
| Startup log line printed three times | Module-level code runs on every import; reloader + worker are separate processes | Use a lifespan handler; log the PID | Side effects at import scale with processes |
| Log line silently broken | Four arguments, three placeholders | Match placeholders to arguments | Logging errors don't crash the app — they go unnoticed |
| `/health` still reported the old version | Config is read once at process start; `--reload` watches `.py` only | Restart the process | Same inheritance rule again |
| App started with `SECRET_KEY=` empty | Required means present, not non-empty | `Field(min_length=16)` | Silent security failures are the dangerous kind |
| Traceback printed configuration values | Plain `str` renders in reprs | `SecretStr` | Make secrets hard to print by accident |
| Laptop had stale code | Committed but never **pushed** | `git push` | A commit is local |
| `.env.example` missing on the second machine | Never created | Create and commit it | Documentation agreed to but not written is worth nothing |
| `docker: command not found` in Ubuntu | Docker Desktop WSL integration off for that distro | Enable it, open a new terminal | Client/server; and PATH again |
| `ports are not available: 5432` | Host port already taken | Map `127.0.0.1:5434:5432` | Host ports are a shared finite resource |
| `container is not running` on `exec` | It failed to start; `docker ps` hides it | `docker ps -a`, read the logs | Created ≠ running |
| `The container name is already in use` | Old container not removed | `docker rm -f novatech-db` | Names are unique per host |
| Table gone after recreating the container | No volume; writable layer deleted with the container | `-v novatech-db-data:/var/lib/postgresql/data` | Containers are ephemeral by design |
| `FATAL: the database system is starting up` | Queried immediately after `docker run -d` | Wait for `pg_isready` | Running ≠ ready |
| A test that "passed" but proved nothing | `SecretStr` tested with no secret loaded; `CREATE TABLE` succeeding meant the data had **not** persisted | Re-run so the test can actually fail | A test that passes for the wrong reason is worse than no test |

---

# 3. Interview questions

Cover the answers. Say yours out loud first.

**Q: Why would a company migrate to AWS when they already own their servers?**
Owned hardware carries hidden costs — power, cooling, space, staff, and a refresh cycle every few years — and must be sized for peak demand, so most capacity sits idle. That's total cost of ownership versus purchase price. Beyond cost: a single server is a single point of failure, capacity can't grow quickly, and backup and recovery are manual work requiring specialist staff. Cloud offers redundancy across Availability Zones, elasticity, managed backups, and lets the team work on the product instead of hardware.

**Q: Scalability versus elasticity?**
Scalability is the ability to handle more load by adding resources. Elasticity is doing that automatically in response to demand — and shrinking again when demand falls.

**Q: What are the risks of migrating?**
Cost overruns without governance; downtime and compatibility issues at cutover; vendor lock-in as you adopt provider-specific services; and a skills gap, where inexperienced configuration causes security exposure.

**Q: Your app binds to `0.0.0.0`. Isn't that insecure?**
`0.0.0.0` means the process accepts connections on any interface the machine has — not that anyone can reach it. It's required in production so the load balancer can connect. Reachability is controlled elsewhere: the app runs in a private subnet with no route to an internet gateway, its security group admits traffic only from the load balancer's security group, only the load balancer is public, network ACLs add a coarser subnet-level filter, and the application still authenticates every request. Defense in depth.

**Q: How does your application get its database password in production?**
Never from source or Git. It lives in AWS Secrets Manager. Either the platform injects it as an environment variable at container start — simple and keeps the app portable, but rotation requires a restart — or the application fetches it via the SDK, which allows re-reading after rotation. Better still, RDS IAM authentication issues a short-lived token from the instance's role, so no long-lived password exists.

**Q: Why not keep configuration in a file in the repository?**
It would contain secrets, and it bakes configuration into the build artifact — so you'd need a different artifact per environment, and what you tested is not what you shipped. Environment-supplied config means one artifact runs everywhere and only the environment changes.

**Q: You changed an environment variable on a running service. When does the app see it?**
Only after a restart or redeployment. A process receives a copy of its environment when it starts; later changes don't reach it.

**Q: Which config values should have defaults?**
Default the harmless, require the dangerous. A port or log level can default safely. A signing secret cannot — a default would mean every deployment that forgot to set it shares a publicly-known key, and the app would run perfectly while being insecure. It should refuse to start, and the constraint must reject empty values as well as missing ones.

**Q: Two customers order the last item simultaneously. How do you prevent overselling?**
Make the check and the decrement one conditional statement inside a transaction: `UPDATE products SET quantity = quantity - :n WHERE id = :id AND quantity >= :n`. The first transaction takes an exclusive row lock; the second blocks, then re-evaluates against committed data when the lock releases, matches zero rows, and is rejected. A separate `SELECT` then `UPDATE` leaves a window between check and use — TOCTOU — during which state can change.

**Q: Why store the price on the order rather than reading it from the product?**
An order is a historical record of a transaction. If it referenced the current price, changing a product's price would retroactively change what past orders were worth, corrupting revenue reporting.

**Q: Why soft-delete products?**
Orders reference products by foreign key. Hard deletion would either violate the constraint or, with cascade, destroy order history. Soft delete keeps the row and hides it from inventory. The cost is that every product query must filter on `is_active`, and retired SKUs can't be reused.

**Q: Why JWTs instead of sessions, and what's the downside?**
With multiple instances behind a load balancer, in-memory sessions break because a user's next request may hit a different instance. The alternatives are sticky sessions, which fail when an instance dies, or a shared session store, which is another component to run. Stateless JWTs let any instance verify a token independently. The trade-off is that a token can't be revoked before it expires, so a stolen token stays valid and logout is client-side only — mitigated by short lifetimes. A denylist would restore revocation but reintroduce shared state.

**Q: Should a health check test the database?**
It depends what the check is for. Readiness — should traffic be routed here — should check dependencies, because an instance that can't reach the database can't serve real requests. Liveness — should this process be restarted — should not, because if every instance fails simultaneously the load balancer removes all targets and the platform may start replacing instances, each one hammering a recovering database and prolonging the outage. Ideally they're separate endpoints. Either way the check must be cheap, unauthenticated, and excluded from access logs.

**Q: What's the difference between a container and a virtual machine?**
A VM emulates hardware and runs its own kernel. A container is a process on the host kernel, isolated by namespaces and constrained by cgroups. Containers start in milliseconds and are much smaller, but share the host kernel.

**Q: What happens to data written inside a container?**
It goes to the container's thin writable layer and is destroyed with the container. Persistent data requires a volume — storage managed outside the container's lifecycle.

**Q: Why use RDS instead of running PostgreSQL in a container?**
Because state is the hard part. Running it yourself means owning storage durability, backups, tested restores, failover when the host dies, patching, and replication. RDS transfers that operational burden. Application containers are stateless and disposable; the database is neither.

**Q: You deployed and the app can't reach the database. How do you investigate?**
Work outward in layers. Is the app process running and did it start cleanly? What do its logs say — connection refused, timeout, or authentication failure? Refused suggests nothing is listening; a timeout suggests traffic is being dropped by a security group, network ACL, or routing; authentication failure means connectivity works and the credentials are wrong. Then check that the database is actually ready rather than merely started, that the security group admits the application's security group on the database port, that the app is in a subnet with a route to the database, and that the connection settings point at the right host and port.

---

# 4. Command reference

**Git**

```
git status                    # always, before and after
git fetch                     # update knowledge of the remote; changes nothing local
git log --oneline --graph --all -8
git add <file> / git add -A
git commit -m "what and why"
git push
git checkout -- <file>        # DISCARDS local changes to that file, permanently
```

**Linux**

```
pwd / ls -la / cat <file>
sudo apt update && sudo apt upgrade -y
ps aux | head -20
sudo ss -tulpn | grep <port>  # listening sockets, with process names
echo $?                       # exit code of the last command
echo $PATH
```

**Python**

```
python3 -m venv .venv
source .venv/bin/activate     # per shell, every time
pip install -r requirements.txt
pip freeze > requirements.txt
```

**Docker**

```
docker version                       # Client AND Server sections
docker ps            / docker ps -a
docker logs <name>
docker inspect <name> --format '{{json .Mounts}}'
docker exec -it <name> <command>
docker rm -f <name>
docker volume ls
docker run --name <name> -e KEY=value -p 127.0.0.1:HOST:CONTAINER \
  -v <volume>:/path -d <image>:<tag>
```

**PostgreSQL**

```
docker exec novatech-db pg_isready -U novatech
docker exec -it novatech-db psql -U novatech -d novatech
\dt        # list tables      \q  quit      \pset pager off
```

---

## Milestones completed

- [x] Development environment (both machines)
- [x] Linux fundamentals
- [x] Git / GitHub
- [x] Local application — API with `/health` and environment-driven configuration
- [x] PostgreSQL running in a container with persistent storage
- [ ] Application connected to the database
- [ ] Docker Compose
- [ ] Cloud fundamentals → AWS → networking → Terraform → migration
