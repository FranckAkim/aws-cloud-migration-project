# Study Guide 05 — RDS, Secrets and the Data Migration

NovaTech migration project · Phase 5

The phase where the data actually left the laptop. A managed PostgreSQL instance
in private subnets, credentials that no human ever sees, a private path in
without a bastion or an open port, and a least-privilege application role.

---

## 1. Phase report

**Goal:** move the database out of a container on a laptop and into a managed
service, without ever putting a password in code, state, git, a command line or
a terminal.

**What now exists**

| Resource | Value | Cost / month |
|---|---|---|
| RDS PostgreSQL 17.9 | `novatech-dev`, `db.t4g.micro`, single-AZ | ~$11.70 |
| Storage | 20 GB gp3, encrypted, autoscaling to 50 GB | ~$2.30 |
| Automated backups | 7 days retention | $0 (free up to DB size) |
| DB subnet group | the two private data subnets | free |
| Parameter group | `rds.force_ssl=1`, slow-query logging | free |
| RDS-managed master secret | created and owned by RDS | ~$0.40 |
| Application credentials secret | `novatech-dev/db/app` | ~$0.40 |
| Admin host + NAT | **destroyed after use** | ~$0.05/hour while on |
| **Total always-on** | | **~$14.80** |

**Data migrated and verified:** 3 tables, 3 users, 4 products, 2 orders, with all
ID sequences correctly positioned.

**Files added**

```
infrastructure/terraform/dev/
├── rds.tf       # subnet group, parameter group, instance
├── secrets.tf   # the application credentials secret (container only)
└── admin.tf     # IAM role, instance profile, SG, SSM-managed admin instance
```

---

## 2. Build steps, in order

1. **Price it before building it.** Instance + storage + secrets, and identify
   what bills when idle. → a number you said out loud before applying.
2. **Write `rds.tf`**: subnet group over the data subnets, custom parameter
   group, instance with `manage_master_user_password`, encryption on,
   `publicly_accessible = false`.
3. **`terraform plan`** → `3 to add, 0 to destroy`; confirm no password appears
   anywhere in the plan and `storage_encrypted = true`.
4. **`terraform apply`** → ~9 minutes. Outputs give the endpoint and the master
   secret's ARN, never the password.
5. **Write `admin.tf`**: IAM role with `AmazonSSMManagedInstanceCore` plus a
   one-secret read policy, instance profile, a security group with **no inbound
   rules**, a `t4g.nano` in a private app subnet, IMDSv2 required.
6. **`terraform apply -var="enable_nat=true" -var="enable_admin_host=true"`**
   → NAT and admin host exist; about 5 cents an hour.
7. **Install the Session Manager plugin and `postgresql-client`** in WSL.
8. **Wait for registration**: `aws ssm describe-instance-information` shows the
   instance `Online`. (It can take several minutes; the agent retries if NAT was
   not ready at boot.)
9. **Dump locally**:
   `docker compose exec -T db pg_dump -U novatech -d novatech --no-owner --no-privileges --clean --if-exists > /tmp/novatech.sql`
10. **Open the tunnel** with `AWS-StartPortForwardingSessionToRemoteHost`
    → `Port 55432 opened`.
11. **Fetch the master password into an environment variable** straight from
    Secrets Manager; print only its length.
12. **Test the connection**: `select version();` → PostgreSQL 17.9.
13. **Restore** with `psql -v ON_ERROR_STOP=1 -f`.
14. **Verify counts and sequences**, not just "no errors".
15. **Create the secret container in Terraform** (`secrets.tf`), then write its
    value with `put-secret-value --secret-string file://…`.
16. **Create the application role** from a generated file, then `shred` the file.
17. **Prove least privilege**: SELECT/INSERT/DELETE succeed, `CREATE TABLE` fails
    with `permission denied for schema public`.
18. **Destroy the hourly resources**: `terraform apply` with no `-var` flags →
    `5 to destroy`.
19. **Commit and push.**

---

## 3. RDS concepts

### What "managed" buys, and what it costs

| AWS does | You still do |
|---|---|
| Provisioning, patching the OS and engine | Schema design and indexing |
| Automated backups and point-in-time recovery | Deciding retention and testing restores |
| Failover to a standby (Multi-AZ) | Making the app reconnect cleanly |
| Monitoring metrics, storage autoscaling | Query tuning, connection pooling |
| Encryption, TLS, parameter management | Choosing sane parameters, least privilege |

You give up superuser: no `rds_superuser`-beyond privileges, no filesystem, no
extensions outside the supported list. That is the trade — less control, far
less operational burden.

### Subnet group

Tells RDS which subnets it may place the instance in, and it **must span at least
two AZs** even for a single-AZ instance, so Multi-AZ can be turned on later
without rebuilding. Ours covers the two data subnets, which have no route to the
internet in either direction.

### Parameter group

The engine's configuration file, as an AWS object. The default group cannot be
edited, so any change means a custom one. Two kinds of parameter:

- **dynamic** — applied immediately (`log_min_duration_statement`)
- **static** — needs a reboot (`rds.force_ssl`), hence
  `apply_method = "pending-reboot"`

`rds.force_ssl = 1` makes the server reject unencrypted connections. Combined
with a security group that only admits the app, that is encryption in transit
enforced by the server rather than trusted to every client.

### Storage

- **gp3** — cheaper and faster than gp2 at small sizes, with baseline IOPS not
  tied to volume size. 20 GB minimum.
- **`max_allocated_storage`** — storage autoscaling. The instance grows when it
  runs low, up to that ceiling. Set it equal to `allocated_storage` to disable.
  Storage can grow but **never shrink**: reducing it means dump and restore into
  a new instance.
- **`storage_encrypted = true`** — free, uses the AWS-managed `aws/rds` KMS key.
  **Only settable at creation.** To encrypt an existing instance you must
  snapshot, copy the snapshot with encryption, and restore. Always switch it on
  from the start.

### Backups and recovery

- **Automated backups** — a daily snapshot plus continuous transaction logs,
  giving **point-in-time recovery** to any second within the retention window.
  Free up to 100% of the database size. `backup_retention_period = 0` disables
  backups entirely, which is also what makes a read replica impossible.
- **Manual snapshots** — kept until you delete them, and they survive the
  instance.
- **`skip_final_snapshot`** — true in dev so destroying leaves nothing behind;
  **never true in production**.
- **`deletion_protection`** — refuses deletion via API or console. True in
  production; false here so the environment stays disposable.

A backup you have never restored is a hope, not a backup. Restoring into a new
instance is the test, and RDS makes it a few clicks.

### Availability

| Feature | Purpose | Cost |
|---|---|---|
| Single-AZ | dev | baseline |
| Multi-AZ instance | automatic failover to a standby, same data | ~2× |
| Multi-AZ cluster | two readable standbys, faster failover | ~3× |
| Read replica | scale reads, or cross-region DR | +1 instance each |

A standby is **not** a backup: a `DROP TABLE` replicates instantly. Backups
protect against mistakes; Multi-AZ protects against hardware and AZ failure.

### Maintenance

`auto_minor_version_upgrade` applies patch releases during the maintenance
window. Major versions are never automatic — they are a planned project with a
tested rollback. Choosing quiet windows (`backup_window`, `maintenance_window`,
both UTC) means AWS does its work when nobody is watching.

`apply_immediately = false` queues modifications until that window, which avoids
an accidental mid-day restart. Set it true only when you have decided the
downtime is acceptable now.

---

## 4. Secrets: three patterns, ranked

**1. RDS-managed master password (best available here)**

```hcl
manage_master_user_password = true
```

RDS generates the password, stores it in Secrets Manager, and can rotate it.
Terraform receives only `master_user_secret[0].secret_arn`. The plaintext exists
in no file, no state, no output, no human's memory.

**2. Terraform-managed container, value written out of band (used for the app user)**

```hcl
resource "aws_secretsmanager_secret" "app_db" {
  name = "${local.name}/db/app"
}
```

Terraform owns the *container*; the *value* is written once with
`put-secret-value --secret-string file://…`. Terraform state never sees it. The
`file://` form matters: a value passed inline would sit in shell history and be
visible to `ps` for the life of the command.

**3. `random_password` + `aws_secretsmanager_secret_version` (common, weaker)**

Convenient and fully automated, but the generated password is stored in
Terraform state in plain text forever. Acceptable only when state is encrypted
and tightly access-controlled — and worth saying out loud as a trade-off rather
than pretending it is not there.

**Anti-patterns:** a password in `terraform.tfvars`, in an environment variable
committed to CI config, in a `docker run -e`, or typed into a terminal where it
lands in history.

### Other Secrets Manager facts worth knowing

- ~$0.40 per secret per month, plus $0.05 per 10,000 retrievals. At scale,
  caching matters.
- Deleted secrets enter a **recovery window of 7–30 days**, during which the name
  cannot be reused. `recovery_window_in_days = 0` deletes immediately — fine for
  a disposable dev secret, wrong for production.
- Parameter Store SecureString is the cheaper alternative (free standard tier)
  but has no built-in rotation and no cross-region replication.

---

## 5. Least privilege inside the database

IAM controls who can reach AWS. It says nothing about what a database user may
do — that is the database's own permission system, and it is a separate job.

```sql
CREATE ROLE novatech_app LOGIN PASSWORD '…';
GRANT CONNECT ON DATABASE novatech TO novatech_app;
GRANT USAGE ON SCHEMA public TO novatech_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO novatech_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO novatech_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO novatech_app;
```

- **`USAGE ON SCHEMA` without `CREATE`** is what makes `CREATE TABLE` fail. That
  failure is the test that the design works.
- **Sequences need their own grant.** Without `USAGE, SELECT ON SEQUENCES`, every
  `INSERT` into a table with a `SERIAL`/identity column fails — a classic
  "read-only in production" incident.
- **`ALTER DEFAULT PRIVILEGES`** applies grants to tables created *in future*.
  Without it, the next migration creates a table the app cannot see.
- In PostgreSQL 15+, `PUBLIC` no longer has `CREATE` on `public` by default,
  which is why the error message is about the schema rather than the table.

Roles worth separating in a real system: a migration role that owns the schema
and may run DDL, an application role that may only touch data, and a read-only
role for analytics.

---

## 6. Reaching a private database: Session Manager

The database has no route to the internet, by design. Four ways to work with it:

| Approach | Inbound ports | Keys to manage | Cost |
|---|---|---|---|
| Make RDS public | 5432 exposed | — | free, unacceptable |
| SSH bastion | 22 open to the world or an IP range | SSH keys | ~$3.65/mo for the public IP |
| Client VPN | none | certificates | ~$0.10/hr + per connection |
| **SSM Session Manager** | **none** | **none** | **instance time only** |

How it works: the SSM agent on the instance makes an **outbound** connection to
the SSM service. Your `aws ssm start-session` call is authorised by IAM and
tunnelled back down that existing connection. Nothing listens for inbound
traffic, there is no key material, and every session is attributable to an IAM
identity and can be logged to S3 or CloudWatch.

```bash
aws ssm start-session --target i-0ceaf… \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<rds endpoint>"],"portNumber":["5432"],"localPortNumber":["55432"]}'
```

`localhost:55432` on the laptop → SSM → the agent → RDS:5432. The RDS DNS name
only resolves inside the VPC, and that is fine because the agent is the one
resolving it.

Requirements: the instance needs an IAM role with `AmazonSSMManagedInstanceCore`
and a network path to the SSM endpoints — via NAT, as here, or via three
interface endpoints (`ssm`, `ssmmessages`, `ec2messages`) at about $22/month if
you want no internet path at all.

### The supporting IAM pieces

- **Role** — a set of permissions with a trust policy. Here the trust policy says
  only `ec2.amazonaws.com` may assume it.
- **Instance profile** — the container that attaches a role to an EC2 instance.
  Terraform creates it explicitly; the console hides it.
- **Managed vs inline policy** — `AmazonSSMManagedInstanceCore` is AWS-maintained,
  so it keeps working as the service evolves. The secret-reading policy is inline
  and hand-written, scoped to exactly one ARN.
- **IMDSv2 (`http_tokens = "required"`)** — the instance metadata service must be
  called with a session token obtained by a `PUT`. This blocks the SSRF attacks
  that trick a web app into fetching role credentials from `169.254.169.254`. It
  is a standard audit finding, and free to fix.

---

## 7. The migration mechanics

```bash
pg_dump -U novatech -d novatech --no-owner --no-privileges --clean --if-exists
```

| Flag | Why |
|---|---|
| `--no-owner` | the local `novatech` role does not exist in RDS; without this every `ALTER … OWNER TO` fails |
| `--no-privileges` | local GRANTs reference roles that do not exist either |
| `--clean --if-exists` | emit `DROP … IF EXISTS` first, so the restore is repeatable |

```bash
psql -v ON_ERROR_STOP=1 -f dump.sql
```

Without `ON_ERROR_STOP`, psql continues past failures and exits 0. That is how
people convince themselves a broken migration succeeded.

**Verification is counts, not silence.** Row counts per table, and the sequence
values (`setval` lines in the dump). If sequences are left at 1, the first insert
collides with an existing primary key — the classic symptom of a hand-rolled
`INSERT`-script migration.

**A real cutover adds:** a rehearsal on a copy, a maintenance window or
logical replication (AWS DMS) for near-zero downtime, a verification query set
agreed in advance, and a written rollback plan. Ours was a dump and restore
because the dataset is tiny and downtime is free.

**Handling the dump file itself:** it contains every row, including password
hashes. `shred -u` it when finished; do not leave it in `/tmp` or, worse, commit
it.

---

## 8. Cost control for this phase

| Decision | Effect |
|---|---|
| `db.t4g.micro`, single-AZ | ~$11.70/month instead of ~$24 Multi-AZ |
| gp3 20 GB | ~$2.30/month; autoscaling prevents a surprise outage, ceiling prevents a surprise bill |
| NAT and admin host behind variables | ~5 cents an hour, only while migrating |
| `skip_final_snapshot = true` (dev) | destroying leaves no lingering snapshot storage |
| `recovery_window_in_days = 0` on the app secret | no orphaned secret blocking the name |

**Stopping versus destroying**

```bash
aws rds stop-db-instance --db-instance-identifier novatech-dev   # up to 7 days, storage still billed
terraform apply                                                  # drops NAT + admin host
terraform destroy                                                # removes everything in the stack
```

RDS restarts a stopped instance automatically after 7 days, so "stopped" is a
pause, not a switch-off. For a longer break, take a manual snapshot and destroy.

---

## 9. Troubleshooting log

| Symptom | Cause | Fix | Principle |
|---|---|---|---|
| `describe-instance-information` returned an empty table | The admin host had only just booted; NAT and the instance are created in parallel, so the agent's first registration attempt can fail | Waited ~5 minutes and re-checked | Diagnose in order: does the resource exist → is there a route → has the agent had time |
| Terminal stuck showing `(END)` | psql opened its pager | `q`, then `-P pager=off` or `PSQL_PAGER=cat` | Non-interactive output needs the pager disabled |
| `NOTICE: table … does not exist, skipping` during restore | `--clean --if-exists` against an empty database | Nothing | Read notices before treating them as errors |
| `permission denied for schema public` as the app user | Intended | Nothing | The failure *is* the test result |
| `cd` failed in a pasted block | Already in that directory | Nothing | Harmless, the rest of the block still runs |

---

## 10. Interview questions

**Why RDS rather than PostgreSQL on EC2?**
Backups, patching, failover, monitoring and encryption are handled, which at
small team size is most of the operational cost of running a database. You give
up superuser and filesystem access. Self-managed makes sense when you need an
unsupported extension, a specific fork, or extreme cost control at scale.

**How do you protect a database at the network level?**
Private subnets with no route to the internet, a security group that admits only
the application's security group on 5432, `publicly_accessible = false`, and no
inbound path from anywhere else. Two independent controls — routing and security
groups — must both fail before exposure.

**Where does the database password live?**
Nowhere a person can see. RDS generates the master password and stores it in
Secrets Manager; Terraform gets only the ARN. The application has a separate,
lesser credential whose value was written straight from a generator into Secrets
Manager and never entered state, git, or a command line.

**Your Terraform state contains a database password. Is that acceptable?**
It is a known trade-off of the `random_password` pattern. Mitigate with an
encrypted, versioned, access-controlled backend — or avoid it entirely with
`manage_master_user_password` or an out-of-band write, which is what we did.

**How do you connect to a database in a private subnet?**
Session Manager port forwarding through an instance with an SSM role. No inbound
ports, no SSH keys, IAM-authorised and auditable. A bastion with port 22 open is
the older answer and a worse one.

**What is IMDSv2 and why require it?**
The instance metadata service, session-token based. Requiring it blocks
server-side request forgery attacks that would otherwise let an attacker read the
instance's role credentials through a vulnerable web app.

**Walk me through migrating a database with minimal downtime.**
Rehearse on a copy. For small data: quiesce writes, `pg_dump`, restore, verify
counts and sequences, repoint the app. For large data or tight windows: AWS DMS
or logical replication to sync continuously, then a short cutover once lag is
near zero. Always have a written rollback and an agreed verification query set.

**How do you verify a migration succeeded?**
Row counts per table, sequence positions, a sample of referential-integrity
checks, and an application smoke test against the new database. Not "psql printed
no errors".

**What does `ALTER DEFAULT PRIVILEGES` do and why does it matter?**
It grants privileges on objects created *in future* by a given role. Without it,
a new table from the next migration is invisible to the application user, so the
deploy passes and the feature fails.

**Multi-AZ or a read replica?**
Multi-AZ is availability: a synchronous standby that fails over automatically,
not readable. A read replica is asynchronous and readable, used to scale reads or
for cross-region DR. Neither is a backup — both replicate a `DROP TABLE`.

**How do you keep a dev database cheap?**
Smallest burstable instance, single-AZ, minimal storage with an autoscaling
ceiling, stop it when idle, destroy it for longer breaks, and keep the
always-on extras (NAT, jump hosts) behind Terraform variables.

---

## 11. Command reference

```bash
# ---- RDS
aws rds describe-db-instances --db-instance-identifier novatech-dev \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Engine:EngineVersion,AZ:AvailabilityZone,Public:PubliclyAccessible,Encrypted:StorageEncrypted}'
aws rds stop-db-instance  --db-instance-identifier novatech-dev    # max 7 days
aws rds start-db-instance --db-instance-identifier novatech-dev
aws rds create-db-snapshot --db-instance-identifier novatech-dev \
  --db-snapshot-identifier novatech-dev-manual-$(date +%Y%m%d)
aws rds describe-db-log-files --db-instance-identifier novatech-dev

# ---- Secrets (never print a secret value)
aws secretsmanager list-secrets --query 'SecretList[].Name'
aws secretsmanager put-secret-value --secret-id "$ARN" --secret-string file:///tmp/secret.json
export PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$ARN" \
  --query SecretString --output text | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')

# ---- Session Manager
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}' --output table
aws ssm start-session --target i-xxxx                              # interactive shell
aws ssm start-session --target i-xxxx \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<rds-endpoint>"],"portNumber":["5432"],"localPortNumber":["55432"]}'

# ---- migration
docker compose exec -T db pg_dump -U novatech -d novatech \
  --no-owner --no-privileges --clean --if-exists > /tmp/novatech.sql
psql "$PGURL" -v ON_ERROR_STOP=1 -f /tmp/novatech.sql
psql "$PGURL" -P pager=off -c "\dt" -c "select count(*) from users;"
shred -u /tmp/novatech.sql

# ---- useful psql
\dt            list tables          \du     list roles
\d products    describe a table     \dp     table privileges
\l             list databases       \conninfo  current connection details
```

---

## 12. Milestones and gaps

**Reached**

- Data lives in a managed, encrypted, backed-up PostgreSQL instance with no path
  to or from the internet.
- No database password exists in code, state, git, history or anyone's memory.
- The application has its own credential that cannot alter the schema, proven by
  a deliberate failure.
- Private access is possible without a bastion, an open port or an SSH key.
- Hourly-cost resources live behind Terraform variables and are destroyed after
  use.

**Gaps**

- The application still runs locally against the local container — ECS is next.
- No automatic rotation on the application secret (RDS can rotate the master one).
- No restore rehearsal yet: backups exist but have never been tested.
- No CloudWatch alarms on CPU, storage, connections or replica lag.
- No Performance Insights (free tier available) for query-level diagnosis.
- Single-AZ, and `deletion_protection` off — both correct for dev, both wrong for
  production.
- Schema changes are applied by hand; a migration tool such as Alembic belongs in
  the deployment pipeline.
- The app connects with `sslmode=require`; `verify-full` with the RDS CA bundle
  would also authenticate the server.
