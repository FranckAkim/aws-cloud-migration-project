# Study Guide 03 — Authentication, and AWS Foundations

**Covers:** JWT authentication, password hashing, the completed API, automated tests, a secrets-in-image bug, AWS account security, IAM, CLI credentials, and Amazon ECR
**Project phases:** end of 1 (application complete), 4 and 5 (cloud and AWS foundations)
**Mode:** build mode — code supplied and tested, concepts kept short

---

## Phase report

**What was built**

- The application is now feature-complete against the design document: JWT login, product create/update/soft-delete, order list/view/status changes, and an operator script for creating users.
- A 13-test automated suite runs against a real PostgreSQL database, including concurrency tests for overselling and double-restocking.
- A real security bug was found and fixed: `application/backend/.env` — containing the signing key and database password — had been baked into every Docker image built so far.
- The AWS account was secured: root has MFA and no access keys, an IAM user `Dee` with MFA does all daily work, a budget alert is in place, and the CLI uses short-lived credentials rather than stored keys.
- The first AWS resource exists: a private ECR repository `novatech-api` holding the application image, tagged with its Git commit, immutable, and scanned on push.

**State of the system**

| Component | Where | Status |
| --- | --- | --- |
| API (FastAPI) | Local, Docker Compose | Complete, authenticated, tested |
| PostgreSQL 17 | Local, Docker Compose | Schema from `01-schema.sql`, persistent volume |
| Container image | Amazon ECR, `us-east-1` | Pushed, scanned |
| AWS identity | IAM user `Dee` via `aws login` | MFA, temporary credentials |

**Cost to date:** effectively zero. ECR storage is $0.10 per GB-month and the image is about 55 MB compressed — well under one cent a month. Nothing is running in AWS that bills by the hour.

**Nothing needs destroying.** The ECR repository is cheap to keep and is used in the next phases.

---

## Build steps, in order

Each step is paired with the check that proves it worked.

**Complete the application**

1. Add `auth.py` (Argon2id hashing, JWT issue/verify), `schemas.py` (request models), expand `db.py` and `main.py` to the full API, and add `create_user.py`. *Verify:* 13 automated tests pass.
2. Raise `SECRET_KEY`'s minimum to 32 characters — HS256 needs a key at least as long as its 32-byte hash output.
3. Add the tests (`tests/conftest.py`, `tests/test_api.py`) with a guard that refuses to run unless `DATABASE_NAME` ends in `_test`, since they wipe the database.

**Fix the image leak**

4. *Check first:* `docker compose exec api ls -la /app` showed `.env` inside the image.
5. Rewrite `.dockerignore` with `**/` prefixes (`**/.env`, `**/__pycache__/`, …). *Verify:* rebuild, list `/app` again — `.env` is gone.

**Dependencies and secrets**

6. With the venv active: `pip install pyjwt "pwdlib[argon2]" python-multipart`, then `pip freeze > requirements.txt` **before** installing test tools, so pytest never reaches the production image. *Verify:* `grep` for the new packages.
7. `pip install -r requirements-dev.txt` for pytest and httpx.
8. Generate a 64-character key and write it into both `.env` files **without printing it**, using `sed`. *Verify:* `awk` prints only the key length.
9. `docker compose up -d --force-recreate api`. *Verify:* status `healthy`.

**Exercise the application**

10. `docker compose exec api python create_user.py` — run on its own, never in a pasted block.
11. *Verify:* `curl -i http://localhost:8080/api/products` → **401**; log in via **Authorize** at `/docs`.
12. `DATABASE_NAME=novatech_test DATABASE_HOST=localhost DATABASE_PORT=5434 python -m pytest -q tests` → **13 passed**.
13. Commit and push, checking `git status` shows no `.env`.

**Secure the AWS account**

14. As root: confirm MFA is assigned and no access keys exist; create a monthly **budget** with email alerts at 50/80/100%; enable **IAM access to billing**.
15. Create group `Administrators` with the AWS-managed policy `AdministratorAccess`.
16. Create IAM user `Dee` with console access and add it to the group. Save the account sign-in URL.
17. Sign in as `Dee`, switch the console region to **US East (N. Virginia)**, and assign an **MFA** device.
18. Install AWS CLI v2 inside WSL.
19. `aws logout` (clearing the root session), then `aws login --profile novatech` and sign in **as Dee** in the browser. Set the region and `export AWS_PROFILE=novatech` in `~/.bashrc`.
20. *Verify both:* `aws sts get-caller-identity` ends in `user/Dee`; `aws iam get-account-summary --query 'SummaryMap.AccountAccessKeysPresent'` prints `0`.

**First AWS resource: ECR**

21. Set shell variables (`REGISTRY`, `REPO`, `TAG` from `git rev-parse --short HEAD`) and `AWS_PAGER=""`.
22. `aws ecr create-repository` with `scanOnPush=true` and `IMMUTABLE` tags; attach a lifecycle policy keeping the last 10 images.
23. `aws ecr get-login-password | docker login --password-stdin`, then build, tag and push.
24. *Verify:* `aws ecr describe-images` lists the tag; `describe-image-scan-findings` returns severity counts.

---

# 1. Application security concepts

## 1.1 How JWT authentication works here

1. The client posts email and password to `/api/auth/login`.
2. The server verifies the password hash and returns a signed token containing `sub` (user id), `iat` (issued at) and `exp` (expiry, 60 minutes).
3. The client sends `Authorization: Bearer <token>` on every request.
4. Each endpoint that declares a `CurrentUser` parameter runs a dependency that verifies the signature and expiry and yields the user id — or returns **401**.

No session is stored anywhere. Any application instance can verify any token using the shared `SECRET_KEY`, which is what lets the service scale horizontally behind a load balancer.

**Pin the algorithm.** `jwt.decode(..., algorithms=["HS256"])` — never accept whatever algorithm the token itself names. Otherwise a forged token declaring `alg: none` (no signature at all) can be accepted by careless libraries. The test suite checks that unsigned, forged, tampered and expired tokens are all rejected.

## 1.2 Storing passwords

Passwords are hashed with **Argon2id**, never stored or logged.

A general-purpose hash like SHA-256 is the wrong tool precisely *because* it is fast: an attacker with a stolen database can test billions of guesses per second. Password hashes are deliberately **slow and memory-hard**, and include a random **salt** per password so identical passwords produce different hashes and precomputed tables are useless.

## 1.3 Don't reveal which accounts exist

A wrong email and a wrong password return the **same error, with the same timing**. When the email is unknown, the server still verifies the password against a dummy hash, so the response takes as long as a real failed login. Without this, response times reveal which emails have accounts — a first step in targeted attacks.

## 1.4 Identity comes from the token, never the request

Earlier, `POST /api/orders` accepted a `user_id` in the body — so anyone could place orders as anyone. Now the user comes from the verified token and any `user_id` in the body is ignored. The general flaw has a name: **Insecure Direct Object Reference**, or more broadly, trusting the client about who it is.

## 1.5 No public sign-up

NovaTech is an internal tool, so accounts are created by an operator (`create_user.py`) rather than through an open registration endpoint. The smallest attack surface is an endpoint that doesn't exist.

## 1.6 Order status as a state machine

Allowed transitions: `pending → shipped` and `pending → cancelled`. Shipped and cancelled are final; anything else is **409 Conflict**. Setting the status it already has is a no-op returning 200 — an **idempotent** operation, safe to retry.

Cancelling returns the stock. Two simultaneous cancels must not restock twice, so the order row is locked with **`SELECT ... FOR UPDATE`** (pessimistic locking): the second request waits, then sees the order is already cancelled and changes nothing. A test fires six simultaneous cancels and confirms stock is restored exactly once.

## 1.7 Tests as a safety net

The suite runs the real application against a real PostgreSQL database — integration tests, not mocks — and resets the schema before every test so each starts clean. It covers the behaviours that matter most and are easiest to break silently: authorisation, rollback on failure, overselling under concurrency, and double-restocking.

Because the tests destroy data, they **refuse to run** unless `DATABASE_NAME` ends in `_test`. A guard that makes the dangerous mistake impossible beats a warning in a README.

These tests become the first stage of the CI pipeline, which would have caught the broken `requirements.txt` pushed during this phase before it ever left the machine.

## 1.8 The `.dockerignore` bug

`.gitignore` patterns match at any depth. **`.dockerignore` patterns are anchored to the build-context root.** So `.env` excluded only the root `.env`, while `application/backend/.env` — real signing key, real database password — was copied into every image by `COPY application/backend/ ./`. Anyone able to pull the image could read it.

Fix: `**/.env`, `**/__pycache__/`, and so on. Found by reading the repo, confirmed by listing `/app` inside the running container, and fixed **before** the first push to ECR — otherwise the secrets would have been uploaded to AWS.

## 1.9 Handling secrets in practice

- Generate them properly: `python -c "import secrets; print(secrets.token_urlsafe(48))"`.
- **A secret that has been displayed or shared is compromised.** One was pasted into a chat during this phase; it was replaced.
- Write secrets into files without echoing them: generate into a shell variable, `sed` it into place, `unset` the variable, and verify only the *length*.
- HMAC-SHA256 keys should be at least 32 bytes; the config now refuses anything shorter.

## 1.10 Dependency files

`requirements.txt` holds what the application needs at runtime and is what the image installs. `requirements-dev.txt` (`-r requirements.txt` plus pytest and httpx) holds tools only developers and CI need. Freeze runtime dependencies **before** installing dev tools, or test tooling ends up in production images — bigger, slower, and more to patch.

---

# 2. AWS foundations

## 2.1 The shared responsibility model

AWS secures **the cloud**: data centres, hardware, hypervisors, the infrastructure behind managed services. You secure **what you put in it**: data, identities and permissions, network configuration, anything you run and patch. AWS will not stop you from making a bucket public or leaking a key. Almost every headline "cloud breach" is a customer-side misconfiguration.

Account security and the bill sit entirely on your side of the line.

## 2.2 The root user

The email the account was created with. Unlimited power — including closing the account and changing billing — and **its permissions cannot be restricted by any policy**.

Practice: **MFA on root, no access keys for root, then stop using it.** It is needed for a handful of tasks only (for example, managing root's own credentials). Daily work happens as an IAM identity.

## 2.3 IAM vocabulary

| Term | Meaning |
| --- | --- |
| **User** | A persistent identity, able to hold long-lived credentials (password, access keys) |
| **Group** | A collection of users; permissions attach to the group, users inherit |
| **Policy** | A JSON document of allowed or denied actions on resources |
| **Role** | An identity that is *assumed* temporarily and issues credentials that expire on their own |

Permissions attach to the **role someone plays** (the group), not to the individual — even with a single user.

**Least privilege, applied where it matters.** The human building everything in a personal account uses `AdministratorAccess`, protected by MFA; a restrictive policy there mostly produces "access denied" and teaches nothing. **Machine identities** — the role an application runs as — get exactly the permissions they need and nothing more, because that is the credential an attacker inherits by exploiting the application. That is applied in the security phase. In organisations, human access is managed with IAM Identity Center and separate accounts per environment.

## 2.4 Credentials: long-lived versus temporary

| Kind | Lifetime | Where used |
| --- | --- | --- |
| Access key (ID + secret) | Until someone deletes it | Legacy CLI setups; the most commonly leaked AWS credential |
| `aws login` session | Refreshes up to 12 hours, then expires | A person using the CLI with their console sign-in (and MFA) |
| Role credentials | Minutes to hours | EC2 instances, ECS tasks, Lambda, CI pipelines |

A stolen access key works until someone notices. A stolen temporary credential stops working on its own. Prefer temporary credentials everywhere; this project uses **no access keys at all**.

## 2.5 Knowing who you are

`aws sts get-caller-identity` is the AWS equivalent of `whoami`, and the first command to run when anything fails unexpectedly. The ID prefix tells you the identity type at a glance:

| `UserId` looks like | Identity |
| --- | --- |
| The 12-digit account number | **Root** |
| `AIDA…` | IAM user |
| `AROA…:session` | Assumed role |

`aws configure list` shows **where** the current credentials came from — environment variable, config file, credentials file, or `login` — which is how this phase's credential mystery was solved.

## 2.6 MFA

Authenticator codes (TOTP) are derived from a shared secret plus the current time. So a phone clock that has drifted produces rejected codes, and **the QR code shown during setup *is* the secret** — anyone who sees it can generate valid codes. Never screenshot it. Passkeys and hardware security keys are stronger still, because they resist phishing.

## 2.7 Regions

Most AWS resources live in one **region** and are invisible from others; the console shows only the region selected in the top bar. IAM, billing and budgets are **global**. This project uses **`us-east-1`** throughout. A mismatch between console region and CLI region is a classic cause of "my resource disappeared".

## 2.8 Cost controls

A **budget** with alerts is free and is the first thing to create in any account. **IAM access to billing** must be switched on, or even administrators get access denied on billing pages. Cost Explorer takes about 24 hours to prepare data on first use.

## 2.9 Amazon ECR

A private registry for container images; ECS pulls from it at deployment time.

- **Tag with the Git commit SHA**, not `latest`. Every image traces back to the exact code that built it.
- **Immutable tags**: once pushed, a tag can never point at different content, so what is deployed is exactly what was built and scanned.
- **Scan on push**: a free check against known vulnerabilities (CVEs). Findings in the base OS image are normal and are handled in the security phase.
- **Lifecycle policy**: expire all but the newest 10 images so storage cost cannot creep upward.
- **Login via stdin**: `get-login-password | docker login --password-stdin` keeps the token out of the process list and shell history. The token lasts 12 hours.

The repository was created with the CLI. In the Terraform phase it will be brought under management with `terraform import` — the standard way to adopt infrastructure that already exists.

---

# 3. Troubleshooting log

| Symptom | Cause | Fix | Principle |
| --- | --- | --- | --- |
| `.env` listed in `/app` inside the container | `.dockerignore` patterns are root-anchored | `**/.env` and friends | Check what actually ended up in the artifact |
| `pip: command not found` | venv not active in that shell | `source .venv/bin/activate` | Activation is per shell |
| API container `Restarting (1)`, `No module named 'jwt'` | `requirements.txt` never updated, so the image lacked the package | Update and rebuild | Restart policies turn crashes into loops; read the logs |
| `secret_key ... at least 32 items ... not 30` | Old key still in the root `.env` | Generate a 64-character key | Fail fast doing its job |
| Secret pasted into a chat | Human error | Rotate it; write secrets without displaying them | A displayed secret is a compromised secret |
| Pasted block stalled at `Name:` | An interactive command consumed the following lines as keyboard input | Run interactive commands alone | Anything after a prompt becomes its input |
| `A user with this email already exists` | Placeholder test user from earlier | Use a different email | UNIQUE constraint, cleanly reported |
| pytest `Refusing to run` | No `_test` database name set | Prefix the environment variables | The guard is working |
| `aws: command not found` in WSL | CLI installed only on Windows | Install CLI v2 inside WSL | Two operating systems, two installs |
| `get-caller-identity` returned `:root` | CLI signed in via `aws login` **as root** — first misdiagnosed as a root access key | `aws configure list` showed type `login`; `aws logout`, then log in as Dee | Find the credential *source* before acting |
| `nano` showed `[ New File ]` | `~/.aws/credentials` didn't exist | Exit; investigate elsewhere | An empty result is evidence |
| IAM user sign-in failed | Email typed as IAM username | Username is `Dee` | Email is for root only |
| First IAM username set to `Administrators` | Confusing the user with the group | Named the user `Dee` | Users are who; groups are the role |
| MFA: "Authentication code … not valid" | Stale QR entry or clock drift | Delete app entry, new QR, automatic time | TOTP depends on time and the right secret |
| `gio: Operation not supported` | WSL has no browser | Paste the URL into the Windows browser; `--remote` as fallback | WSL forwards localhost to Linux |
| Console showed Ohio | Default region differed from the CLI's | Switch to N. Virginia | Resources are regional |

---

# 4. Interview questions

**Q: How does your API authenticate requests?**
Login verifies an Argon2id password hash and returns a signed JWT holding the user id and a 60-minute expiry. Each protected endpoint verifies the signature and expiry, with the algorithm pinned so unsigned or re-algorithmed tokens are rejected. It's stateless, so any instance behind the load balancer can verify any token. The trade-off is that a token can't be revoked before expiry, mitigated by the short lifetime.

**Q: How do you store passwords?**
With a slow, memory-hard, salted password hash — Argon2id — never a fast hash like SHA-256, because fast hashes let an attacker test billions of guesses per second against a stolen database. Login failures also take the same time and return the same message whether or not the email exists, so the endpoint doesn't reveal which accounts exist.

**Q: What's wrong with accepting a user id in a request body?**
The client can claim to be anyone. Identity must come from something the server verified — here, the signed token. The general class is insecure direct object reference: trusting client-supplied identifiers for authorisation decisions.

**Q: Walk me through securing a brand-new AWS account.**
MFA on root, confirm root has no access keys, then stop using root. Create a budget with alerts and enable IAM billing access. Create an administrators group, an IAM user in it with MFA, and do all daily work as that user. For the CLI, use short-lived credentials — `aws login` or IAM Identity Center — rather than access keys. Pick one region and use it consistently.

**Q: Access keys, roles, or `aws login` — which do you use and why?**
Temporary credentials wherever possible. Workloads on AWS use IAM roles, which issue credentials that expire automatically. People use their console sign-in through `aws login` or Identity Center, which goes through MFA and produces sessions that expire. Long-lived access keys are the credential most often leaked, and they work until someone notices — so this project has none.

**Q: How do you tell which identity a CLI command is running as?**
`aws sts get-caller-identity`. The ARN names it; the ID prefix tells you the type — the account number means root, `AIDA` an IAM user, `AROA` an assumed role. If it's unexpected, `aws configure list` shows where the credentials came from.

**Q: Where does least privilege matter most?**
On machine identities. A compromised application acts with its role's permissions and can't ask a human for more, so the role should allow only what the application does. Humans still get scoped access in organisations, typically through Identity Center permission sets and separate accounts per environment.

**Q: Why tag images with a commit SHA and make tags immutable?**
So every deployed image traces to exact source, and so a tag can never be silently repointed at different content. What you tested and scanned is exactly what runs. `latest` tells you nothing and changes under you.

**Q: A secret was committed or pasted somewhere public. What do you do?**
Rotate it immediately — treat it as compromised regardless of how briefly it was exposed. Then remove it from where it leaked, check logs for any use, and fix the process so it can't recur: secrets out of source, out of images, out of command lines, and written without being displayed.

**Q: How would you make sure a Docker image contains no secrets?**
Keep secrets out of the build context with a correct `.dockerignore` — remembering its patterns are root-anchored, so use `**/`. Supply secrets only at runtime. Then verify the artifact itself: list the filesystem of a built image, and add secret scanning to the pipeline.

---

# 5. Command reference

**Application**

```
docker compose up -d --build              # rebuild and restart
docker compose up -d --force-recreate api # restart with new environment only
docker compose exec api ls -la /app       # inspect what is inside the image
docker compose exec api python create_user.py
DATABASE_NAME=novatech_test DATABASE_HOST=localhost DATABASE_PORT=5434 python -m pytest -q tests
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

**AWS identity**

```
aws login --profile novatech               # browser sign-in; temporary credentials
aws logout                                 # clear cached session
aws sts get-caller-identity                # who am I?
aws configure list                         # where did the credentials come from?
aws iam get-account-summary --query 'SummaryMap.AccountAccessKeysPresent'   # must be 0
```

**ECR**

```
aws ecr create-repository --repository-name NAME --image-scanning-configuration scanOnPush=true --image-tag-mutability IMMUTABLE
aws ecr get-login-password | docker login --username AWS --password-stdin REGISTRY
docker build -t REGISTRY/NAME:TAG . && docker push REGISTRY/NAME:TAG
aws ecr describe-images --repository-name NAME --output table
aws ecr describe-image-scan-findings --repository-name NAME --image-id imageTag=TAG
```

---

## Milestones

- [x] Local application — complete, authenticated, tested
- [x] PostgreSQL, Docker, Docker Compose
- [x] AWS account security, IAM, CLI credentials
- [x] ECR — first AWS resource
- [ ] AWS networking — VPC, subnets, routing, security groups
- [ ] Terraform *(learning mode)*
- [ ] RDS and database migration
- [ ] ECS deployment behind a load balancer
- [ ] CI/CD with GitHub Actions
- [ ] Security hardening, monitoring, disaster recovery, cost
- [ ] Kubernetes *(learning mode)*

## Known gaps carried forward

- **No CI yet.** A broken `requirements.txt` was pushed during this phase; a pipeline running the test suite would have blocked it.
- **No login rate limiting.** Nothing currently slows repeated password guessing; failed logins are logged, which is the hook for a CloudWatch alarm later.
- **No token revocation or refresh tokens** — the accepted trade-off of stateless JWTs.
- **Base-image vulnerabilities** reported by the ECR scan are not yet triaged.
- **ECR repository not yet in Terraform** — to be imported.
- **No CloudTrail trail yet.** API activity is kept for 90 days in CloudTrail event history by default; a durable trail to S3 comes in the security phase.
