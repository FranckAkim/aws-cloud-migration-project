# Study Guide 06 — ECS Fargate, the Load Balancer, and the Completed Migration

NovaTech migration project · Phase 6

The phase where the application left the laptop. A container running on Fargate
in private subnets, behind an Application Load Balancer, holding no secrets of
its own, talking to RDS over TLS as a least-privilege user.

---

## 1. Phase report

**Goal:** serve NovaTech from AWS end to end, with nothing on a developer
machine in the request path.

**Proof it worked:** `GET /api/products` and `GET /api/orders` through the load
balancer returned the rows migrated from the laptop, after a login that issued a
JWT signed with a key the container read from Secrets Manager.

**What was built**

| Resource | Detail | Cost while running |
|---|---|---|
| CloudWatch log group | `/ecs/novatech-dev-api`, 7-day retention | pennies |
| ECS cluster | `novatech-dev`, Container Insights off | free |
| Task definition | 0.25 vCPU, 0.5 GB, x86_64, 2 secrets injected | — |
| ECS service | 1 task, private subnets, circuit breaker on | ~$0.0123/hr (~$9/mo) |
| Execution role | pull image, read 2 secrets, write logs | free |
| Task role | empty (plus ECS Exec when enabled) | free |
| ALB | public subnets, HTTP listener | ~$0.0225/hr (~$16/mo) |
| Target group | `ip` targets, `/health` checks | free |
| NAT gateway | required for image pulls and Secrets Manager | ~$0.045/hr (~$33/mo) |
| **Total while serving** | | **~$0.08/hour** |

All of it now sits behind `enable_app`, `enable_nat` and `enable_exec`, so a
plain `terraform apply` leaves only RDS running.

**Application change:** `config.py` gained `database_sslmode` (default `prefer`
locally, `require` in AWS) and `db.py` passes it into the connection string.

---

## 2. Build steps, in order

1. **Make the app configurable for TLS** — a setting, not a hard-coded value, so
   the same image runs locally and in AWS.
2. **Commit, then build and push the image tagged with the commit SHA.**
   → `docker push …:99425f7` succeeds; the tag is immutable.
3. **Write `alb.tf`**: load balancer in the public subnets, target group with
   `target_type = "ip"` and a `/health` check, HTTP listener.
4. **Write `ecs.tf`**: log group, execution role, task role, cluster, task
   definition, service.
5. **Add the second secret container** for the JWT signing key.
6. **Apply with `desired_count = 0`** so nothing tries to start before the
   secret has a value. → 15 to add; ALB and NAT each take ~2 minutes.
7. **Write the JWT key** straight from a generator into Secrets Manager.
8. **Apply again with the default count** → service scales to 1.
9. **Watch it come up**: service events, task status, target health, logs.
   → `RUNNING` / `HEALTHY`, target `healthy`, `GET /health 200` in the logs.
10. **Smoke test through the public URL**: health, 401 without a token, login,
    products, orders.
11. **When login fails**, diagnose rather than guess: raw HTTP code first, then
    the encoding, then the credential.
12. **Enable ECS Exec, force a new deployment**, open a shell in the task and
    reset the password. → `rows updated: 1`.
13. **Re-test the full flow** → token issued, data returned.
14. **Add `enable_app`** so the whole serving layer can be switched off.
15. **Apply with defaults** → ~8 destroyed, hourly cost back to zero.
16. **Commit and push.**

---

## 3. ECS concepts

### The three nouns

| Thing | What it is | Analogy |
|---|---|---|
| **Task definition** | The blueprint: image, CPU, memory, env, secrets, logging, health check | A class |
| **Task** | One running copy of that blueprint | An instance |
| **Service** | The supervisor that keeps N tasks alive and registered with the ALB | A process manager |

Editing the blueprint creates a new **revision** (`novatech-dev-api:2`). The
service then rolls tasks onto it. A task by itself is a one-shot run — useful for
migrations and cron-style jobs; a service is for things that must stay up.

### Fargate versus EC2 launch type

| | Fargate | EC2 |
|---|---|---|
| You manage | nothing below the container | the instances, AMIs, patching, scaling |
| Billing | per vCPU-second and GB-second of the task | per instance hour, used or not |
| Density | one task per micro-VM | many tasks per instance |
| Best at | spiky, small, or few workloads | steady high utilisation, GPUs, special instance types |

Fargate is more expensive per unit of compute and cheaper per unit of attention.
At one task, attention is the scarcer resource.

### `awsvpc` networking

Fargate's only mode: **each task gets its own elastic network interface and
private IP** inside your subnets. Consequences worth knowing:

- Security groups apply per task, which is why `app-sg` can name `alb-sg` as its
  only source.
- Target groups must use `target_type = "ip"`; there is no instance to register.
- Each task consumes an IP from the subnet — size subnets with scale in mind.
- `localhost` inside the task is the task, so the container's own health check
  can call `127.0.0.1:8000`.

### The two IAM roles

This is a standard interview question, and the names are unhelpfully similar.

| | Execution role | Task role |
|---|---|---|
| Used by | the ECS agent, **before** your code runs | your application code, at runtime |
| Typical permissions | pull from ECR, read secrets, write logs | whatever AWS APIs the app calls |
| Ours | `AmazonECSTaskExecutionRolePolicy` + read exactly two secret ARNs | empty (the app calls no AWS APIs) |

If the *execution* role is wrong, the task never starts —
`ResourceInitializationError`. If the *task* role is wrong, the app starts and
then gets `AccessDenied` at runtime.

### Secrets injection

```hcl
secrets = [
  { name = "DATABASE_PASSWORD", valueFrom = "${secret_arn}:password::" },
  { name = "SECRET_KEY",        valueFrom = secret_arn },
]
```

ECS fetches the value with the execution role and sets it as an environment
variable inside the container. The value is not in the task definition, not in
Terraform state, and not in CloudWatch. The `:key::` suffix selects one field
from a JSON secret (the empty positions are version-stage and version-id, which
default to the current version).

Compare with `environment`, which is plain text and visible to anyone who can
call `DescribeTaskDefinition`. Configuration goes in `environment`; anything
secret goes in `secrets`.

### Health checks — there are two, and they are different

| | Container health check | Target group health check |
|---|---|---|
| Who runs it | the ECS agent, inside the task | the ALB nodes, over the network |
| Source address in logs | `127.0.0.1` | the ALB's subnet IPs (`10.20.0.x`, `10.20.1.x`) |
| What it decides | whether ECS replaces the task | whether the ALB sends it traffic |

Both pointed at `/health`. Seeing both in the logs is a neat confirmation that
the whole path works: the second one proves the ALB can reach the task through
the security group chain.

`health_check_grace_period_seconds = 60` stops the ALB from killing a task that
is still starting up — without it, slow-starting apps deploy in a loop.

### Deployments

- **Rolling**, controlled by `deployment_minimum_healthy_percent = 100` and
  `deployment_maximum_percent = 200`: start the new task, wait for healthy, then
  stop the old one. Briefly you have two.
- **Circuit breaker with rollback**: if the deployment cannot reach a steady
  state, ECS reverts to the previous task definition automatically. Without it, a
  bad deploy leaves you with a service that never stabilises.
- **`deregistration_delay = 30`** on the target group: how long the ALB keeps
  sending existing connections to a task being removed. The default 300s makes
  every deploy feel five minutes long.
- **Settings apply to new tasks only.** Enabling ECS Exec on the service did
  *not* affect the running task — it needed
  `aws ecs update-service --force-new-deployment`. Generalise this: changing a
  service setting is not the same as replacing the tasks.

### ECS Exec

`enable_execute_command = true` plus four `ssmmessages:*` actions on the **task**
role gives you `aws ecs execute-command … --command "/bin/sh"` — a shell inside a
running Fargate task, through Session Manager, with no SSH and no open ports.

Requirements, in the order they usually fail:

1. `enable_execute_command` on the service **and a new task after that**.
2. `ssmmessages` permissions on the *task* role (not the execution role).
3. The Session Manager plugin installed locally.
4. A network path to SSM (NAT or interface endpoints).

It is a break-glass tool. Every session is authorised by IAM and recorded in
CloudTrail, and it can be logged to S3 or CloudWatch. Leaving it on permanently
in production means anyone with the right IAM permission has a production shell —
hence the `enable_exec` variable, defaulting to false.

---

## 4. Load balancer concepts

### The object model

```
ALB ── listener (port 80) ── rule ── target group ── targets (task IPs)
```

- **Load balancer** — the public endpoint. Lives in at least two subnets in
  different AZs; AWS runs a node in each and DNS round-robins between them.
- **Listener** — a port and protocol, with a default action.
- **Rule** — optional routing by path, host, header or method. We use only the
  default.
- **Target group** — the set of things traffic goes to, plus the health check
  that decides which of them are eligible.

### Health check tuning

```hcl
interval = 30, timeout = 5, healthy_threshold = 2, unhealthy_threshold = 3
```

Time to be declared healthy: 2 × 30s ≈ one minute. Time to be pulled out: 3 × 30s
≈ 90 seconds. Tighter values react faster but flap on a slow request; looser
values are calm but leave traffic going to a broken task for longer. The
trade-off is worth being able to talk through.

`matcher = "200"` means only a literal 200 counts. Our `/health` returns 503 when
the database is unreachable, so a task that loses the database is removed from
service automatically.

### ALB vs NLB vs CloudFront

| | Use for |
|---|---|
| **ALB** | HTTP/HTTPS, path and host routing, WebSockets, per-request features |
| **NLB** | TCP/UDP, extreme throughput, static IPs, preserving the client IP |
| **CloudFront** | caching and TLS termination at edge locations worldwide |

### The HTTP problem, stated plainly

Our listener is **plain HTTP, which is intentionally insecure and must not be
used in production**. Login credentials and JWTs cross the internet in clear
text; anyone on the path can read or replay them. It exists only because HTTPS
needs a certificate, a certificate needs a domain, and we have no domain yet.

The production shape: register a domain (Route 53, ~$12/year), request a free ACM
certificate, add a 443 listener with that certificate, and change the port 80
listener's default action to a permanent redirect to 443. Add
`Strict-Transport-Security` on responses.

---

## 5. Cost engineering

| Item | Per hour | Per month if left on |
|---|---|---|
| ALB | $0.0225 | ~$16 |
| Fargate task (0.25 vCPU, 0.5 GB) | $0.0123 | ~$9 |
| NAT gateway | $0.045 | ~$33 |
| RDS db.t4g.micro + 20 GB | $0.019 | ~$14 |
| **Everything on** | **~$0.10** | **~$72** |

The switches make this manageable:

```bash
terraform apply -var="enable_app=true" -var="enable_nat=true" -var="image_tag=<sha>"  # up
terraform apply -var="image_tag=<sha>"                                                # down
```

Down leaves only RDS. For a longer break, `aws rds stop-db-instance` or a manual
snapshot plus `terraform destroy`.

**Where the money would go at real scale:** NAT per-GB charges (fix with
interface endpoints once the volume justifies the fixed cost), Fargate tasks
sized by fear rather than measurement, CloudWatch log ingestion, and idle
non-production environments left running overnight and at weekends.

---

## 6. Troubleshooting log

| Symptom | Cause | Fix | Principle |
|---|---|---|---|
| `Running: 0` right after scaling up | The task had not started yet | Waited, then read service events | Read `describe-services … events` first; it narrates everything |
| `aws logs tail` → `ServiceUnavailableException` | Transient CloudWatch error | Retried | Not every error is your fault |
| `execute-command` → "execute command was not enabled when the task was run" | The running task predated `enable_execute_command` | `aws ecs update-service --force-new-deployment` | Service settings apply to new tasks only |
| `describe-tasks` showed `enableExecuteCommand: false` after the apply | Same cause, visible in the data | Polled until the new task appeared | Check the task, not the service, for task-level settings |
| Heredoc ran on the laptop instead of the container | The exec session had failed, so the shell was still local | Re-ran after exec worked | Know which machine your prompt belongs to |
| `python: command not found` (locally) | Ubuntu ships `python3` only | Used `python3` locally, `python` inside the image | Same command, different environments |
| Login returned 401 with the right-looking password | `printf 'username=%s&password=%s'` does not URL-encode; and the stored hash did not match | URL-encoded the form, then reset the password via ECS Exec | Diagnose in layers: transport, encoding, credential |
| `KeyError: 'access_token'` | Parsing a response that was an error body | Printed the HTTP status and raw body first | Never parse before you have looked |
| psql pager swallowed the terminal | Default pager on interactive output | `q`, then `-P pager=off` | Disable pagers in scripted work |

---

## 7. Interview questions

**Describe the request path in this architecture.**
DNS resolves the ALB name to nodes in two public subnets. The ALB accepts 80/443
from anywhere and opens a separate connection to a task in a private subnet on
8000, allowed because `app-sg` admits `alb-sg`. The task queries RDS in a data
subnet on 5432, allowed because `db-sg` admits `app-sg`. The data subnets have no
route to the internet at all.

**Execution role or task role?**
Execution role: used by the ECS agent before the container starts — ECR pull,
secrets, logs. Task role: assumed by the application for its own AWS calls. A
broken execution role means the task never starts; a broken task role means it
starts and then fails at runtime.

**How do secrets reach the container?**
ECS reads them from Secrets Manager with the execution role and injects them as
environment variables. They are not in the image, the task definition, Terraform
state, or logs. The alternative — `environment` — is plain text visible to anyone
who can describe the task definition.

**What happens when you deploy a broken image?**
New tasks fail their health checks, the deployment never reaches steady state,
and the circuit breaker rolls back to the previous task definition. The old tasks
are still serving because `minimum_healthy_percent = 100` keeps them until the
replacements are healthy.

**Why two health checks?**
The container check decides whether ECS replaces the task; the ALB check decides
whether traffic is sent to it. They fail independently — a task can be alive but
unreachable through the security group, and the ALB check is what catches that.

**Fargate or EC2?**
Fargate for spiky or small workloads where not managing instances is worth the
premium; EC2 for steady high utilisation, GPU or specialised instance types, or
when bin-packing many small tasks makes the per-unit cost decisive.

**How do you get a shell in a Fargate task?**
ECS Exec via Session Manager: `enable_execute_command` on the service, four
`ssmmessages` actions on the task role, a new task, and the Session Manager
plugin locally. No SSH, no open ports, IAM-authorised and auditable — and off by
default in production.

**How would you add HTTPS?**
A domain in Route 53, a free ACM certificate validated by DNS, a 443 listener
using it, and the port 80 listener changed to a permanent redirect. Then HSTS on
responses. Until then the deployment is explicitly not production-ready.

**How would you scale this?**
Application Auto Scaling on the ECS service, tracking ALB request count per
target or CPU. Raise `desired_count` for a floor. Beyond that: a bigger database
instance, a read replica, and connection pooling — Fargate tasks scale faster
than a database does.

**How do you roll back?**
Deploy the previous image tag. Because tags are immutable git SHAs, the previous
revision is an exact artefact, not "whatever `latest` was last week". The circuit
breaker does this automatically for failed deployments.

**What is still wrong with this deployment?**
Plain HTTP; one task and one AZ in practice; no autoscaling; no alarms; no
WAF; no CI/CD, so deploys are manual `terraform apply` commands from a laptop
with administrator credentials.

---

## 8. Command reference

```bash
# ---- build and push
export TAG=$(git rev-parse --short HEAD)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <acct>.dkr.ecr.us-east-1.amazonaws.com
docker build -t <acct>.dkr.ecr.us-east-1.amazonaws.com/novatech-api:$TAG .
docker push  <acct>.dkr.ecr.us-east-1.amazonaws.com/novatech-api:$TAG

# ---- service and tasks
aws ecs describe-services --cluster novatech-dev --services novatech-dev-api \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}'
aws ecs describe-services --cluster novatech-dev --services novatech-dev-api \
  --query 'services[0].events[:6].[createdAt,message]' --output text    # the best first look
aws ecs list-tasks --cluster novatech-dev --service-name novatech-dev-api
aws ecs describe-tasks --cluster novatech-dev --tasks "$TASK" \
  --query 'tasks[0].{Last:lastStatus,Health:healthStatus,Stopped:stoppedReason}'
aws ecs update-service --cluster novatech-dev --service novatech-dev-api --force-new-deployment
aws ecs execute-command --cluster novatech-dev --task "$TASK" \
  --container api --interactive --command "/bin/sh"

# ---- load balancer
TG=$(aws elbv2 describe-target-groups --names novatech-dev-api \
     --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table

# ---- logs
aws logs tail /ecs/novatech-dev-api --since 15m
aws logs tail /ecs/novatech-dev-api --follow
aws logs tail /ecs/novatech-dev-api --since 1h --filter-pattern "ERROR"

# ---- smoke test without leaking the password onto the command line
URL=$(terraform output -raw app_url)
read -s -p "password: " PW; echo
PAYLOAD=$(PW="$PW" python3 -c 'import os,urllib.parse;print(urllib.parse.urlencode(
  {"username":"admin@novatech.test","password":os.environ["PW"]}))')
printf '%s' "$PAYLOAD" | curl -s -w '\nHTTP %{http_code}\n' -X POST "$URL/api/auth/login" --data @-
unset PW PAYLOAD

# ---- cost switches
terraform apply -var="enable_app=true" -var="enable_nat=true" -var="image_tag=$TAG"   # up
terraform apply -var="image_tag=$TAG"                                                 # down
```

---

## 9. Milestones and gaps

**Reached — the migration is complete**

- The application runs on AWS with nothing on a laptop in the request path.
- The container holds no secrets: both are injected at start-up from Secrets
  Manager by the execution role.
- The app connects to RDS over TLS as a user that cannot alter the schema.
- Deployments are traceable: the running image is an immutable tag equal to a git
  commit.
- A failed deployment rolls itself back.
- Shell access to a running task requires IAM and is off by default.
- The entire hourly-cost surface is behind three Terraform variables.

**Gaps, in rough priority order**

1. **No HTTPS.** Plain HTTP is intentionally insecure and must not be used in
   production. Needs a domain, an ACM certificate, a 443 listener and a redirect.
2. **No CI/CD.** Deploys are manual commands run with administrator credentials.
   Next phase: GitHub Actions with OIDC — no long-lived AWS keys — running the
   existing tests, building, pushing and applying.
3. **No autoscaling and a single task.** One task means one AZ in practice.
4. **No alarms.** Nothing tells you when the service is unhealthy, the database
   is filling up, or the bill is rising.
5. **No WAF** in front of the ALB, and no rate limiting on login.
6. **Schema changes are manual.** A migration tool belongs in the pipeline.
7. **`enable_exec` and administrator access** are convenient and would be
   tightened in a real environment.
8. **No restore rehearsal** for the database backups.
