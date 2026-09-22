# Study Guide 04 — AWS Networking and Terraform Foundations

NovaTech migration project. Covers the phase that turned a hand-built AWS account
into infrastructure as code: the Terraform state bucket, the dev VPC, and the
import of the existing ECR repository.

---

## 1. Phase report

**Goal:** stop clicking in the console. Everything from here on is described in
code, reviewed as a plan, and applied deterministically.

**What now exists in AWS**

| Resource | Name / value | Cost |
|---|---|---|
| S3 state bucket | `novatech-tfstate-253490749032-us-east-1` | ~$0 |
| VPC | `novatech-dev`, `10.20.0.0/16` | free |
| Public subnets | `10.20.0.0/24` (us-east-1a), `10.20.1.0/24` (us-east-1b) | free |
| App subnets (private) | `10.20.10.0/24`, `10.20.11.0/24` | free |
| Data subnets (private, no internet route) | `10.20.20.0/24`, `10.20.21.0/24` | free |
| Internet gateway | `novatech-dev` | free |
| Route tables | public / app / data | free |
| S3 gateway endpoint | `novatech-dev-s3` | free |
| Security groups | `novatech-dev-alb`, `-app`, `-db` | free |
| NAT gateway | **not created** (`enable_nat = false`) | $0 while off |
| ECR repository | `novatech-api` (imported into Terraform) | ~cents |

**Running cost added this phase: about $0/month.** The only priced items are a
few KB of S3 storage and the container image already in ECR.

**Repository layout added**

```
infrastructure/terraform/
├── bootstrap/        # creates the state bucket. Run once.
│   ├── versions.tf   backend.tf  variables.tf  main.tf  outputs.tf
└── dev/              # the environment itself
    ├── versions.tf   variables.tf  network.tf  security.tf  ecr.tf  outputs.tf
```

---

## 2. Build steps, in order

Each step has the check that proves it worked.

1. **Install Terraform** from HashiCorp's apt repository in WSL.
   → `terraform -version` reports 1.10 or newer.
2. **Confirm the CLI identity.**
   → `aws sts get-caller-identity` shows `user/Dee` and a `UserId` starting `AIDA`.
   A `UserId` equal to the account number means root: stop and fix it.
3. **Write the bootstrap stack** (`versions.tf`, `variables.tf`, `main.tf`,
   `outputs.tf`): an S3 bucket with versioning, SSE-S3 encryption, full public
   access block, `BucketOwnerEnforced`, a TLS-only bucket policy, a
   90-day non-current version expiry, and `prevent_destroy`.
4. **Add Terraform entries to `.gitignore`** before the first run:
   `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars`, `crash.log`.
   → `git status` never lists a state file.
5. **`terraform init`** in `bootstrap/`.
   → provider downloaded, `.terraform.lock.hcl` created.
6. **`terraform fmt -check && terraform validate`.**
   → no output from fmt, "Success!" from validate.
7. **`terraform plan`** and read it.
   → `Plan: 7 to add, 0 to change, 0 to destroy.`
8. **`terraform apply`** → `Apply complete! Resources: 7 added.`
9. **Add `backend.tf`** pointing at the new bucket with
   `key = "bootstrap/terraform.tfstate"` and `use_lockfile = true`, then
   **`terraform init -migrate-state`** and answer `yes`.
   → `aws s3 ls s3://<bucket>/bootstrap/` lists `terraform.tfstate`.
10. **Commit** the bootstrap stack plus `.terraform.lock.hcl` (never `.terraform/`).
11. **Write the dev stack**: VPC, 6 subnets across 2 AZs, 3 route tables, the
    internet gateway, the optional NAT behind `enable_nat`, the free S3 gateway
    endpoint, three security groups, and `import` blocks for the ECR repository
    and its lifecycle policy. Backend key `dev/terraform.tfstate`.
12. **`terraform init`** in `dev/` → "Successfully configured the backend s3!"
13. **`terraform plan`** and inspect the import section.
    → If an imported resource shows "must be replaced", change the **code** to
    match reality and re-plan. Never apply a destroy you did not intend.
14. **`terraform apply`** → `2 imported, 28 added, 1 changed, 0 destroyed`.
15. **Verify idempotence**: `terraform plan` → "No changes."
16. **Verify isolation**:
    `aws ec2 describe-route-tables --filters "Name=tag:Name,Values=novatech-dev-data"`
    → only `10.20.0.0/16 → local` and the S3 endpoint prefix list.
17. **Commit and push** the dev stack.

---

## 3. Terraform concepts

### The model

You declare the desired state; Terraform compares it with recorded state and the
real world, then makes the difference. Three things are always in play:

| | What it is | Where it lives |
|---|---|---|
| Configuration | what you want | `*.tf` in git |
| State | what Terraform created, and the real IDs | S3 bucket |
| Reality | what AWS actually has | AWS |

`plan` = diff of the three. `apply` = carry out the diff. `destroy` = remove
everything in state.

### Core vocabulary

- **Provider** — plugin for one API. `hashicorp/aws`, pinned `~> 6.0` (any 6.x,
  never 7.0, because major versions may break compatibility).
- **Resource** — a thing to create: `resource "aws_vpc" "main" { ... }`.
  Address: `aws_vpc.main`.
- **Data source** — a read of something that already exists:
  `data "aws_availability_zones" "available"`. Never created or destroyed.
- **Variable** — input, with `type`, `default` and optional `validation`.
- **Local** — a computed value used in several places (`local.name`).
- **Output** — a value printed after apply and readable by other stacks.
- **Module** — a reusable folder of resources. Not used yet; each stack is flat.

### State, and why it is guarded

State maps `aws_vpc.main` → `vpc-02c78c...`. Without it Terraform does not know
the resource is "hers" and plans to create a duplicate. State can also contain
sensitive values in plain text (database passwords, for example), so:

- it is **gitignored**, always;
- it lives in a **private, encrypted, versioned** S3 bucket;
- the bucket has `prevent_destroy`;
- `use_lockfile = true` makes Terraform take a lock object in S3 during a run, so
  two applies cannot interleave and corrupt state. (Before Terraform 1.10 this
  required a separate DynamoDB table.)

**Recovering lost state:** the resources still exist and still bill. Use an
`import` block (or `terraform import`) to adopt them back rather than deleting
anything by hand.

### The bootstrap chicken-and-egg

The backend bucket must exist before Terraform can store state in it. Solution: a
small `bootstrap` stack that creates the bucket with **local** state, then a
`backend.tf` and `init -migrate-state` to move its own state into the bucket it
just made. Every later stack points at that bucket from the start, with its own
`key` so stacks never overwrite each other.

### `count`, splats and the positional trap

```hcl
resource "aws_subnet" "public" {
  count             = length(local.azs)
  availability_zone = local.azs[count.index]
}
```

Creates `aws_subnet.public[0]` and `[1]`; `aws_subnet.public[*].id` collects the
IDs. Identity is **positional**: delete the first AZ from the list and every
later subnet shifts index, so Terraform destroys and recreates them.
`for_each` keys resources by a stable name instead and avoids this — prefer it
whenever the collection can change in the middle.

### Expressions used in this stack

| Expression | Result |
|---|---|
| `cidrsubnet("10.20.0.0/16", 8, 10)` | `10.20.10.0/24` |
| `slice(data.aws_availability_zones.available.names, 0, 2)` | first two AZs |
| `[for i, az in local.azs : ...]` | a list comprehension |
| `var.enable_nat ? 1 : 0` | conditional creation via `count` |
| `jsonencode({...})` | JSON policy written as HCL, not a quoted blob |

### `default_tags`

Set once on the provider; every resource it creates inherits them. `tags` is what
you wrote, `tags_all` is what AWS will actually have. Tagging everything
`Project` / `Environment` / `ManagedBy` is what makes cost reports and cleanup
possible later.

### Meta-arguments seen here

- `depends_on` — for dependencies Terraform cannot infer from a reference
  (NAT gateway needs the internet gateway attached first).
- `lifecycle { prevent_destroy = true }` — refuse to delete (state bucket).
- `lifecycle { create_before_destroy = true }` — build the replacement first;
  used on security groups, which cannot be deleted while something references them.
- `import { to = ..., id = ... }` — adopt an existing resource, declaratively.
  Delete the block after the successful apply.

### Reading a plan

| Symbol | Meaning |
|---|---|
| `+` | create |
| `-` | destroy |
| `~` | update in place |
| `-/+` | destroy then create (replacement) |
| `<=` | read (data source) |

`(known after apply)` = AWS assigns it. The only number that should ever surprise
you is **destroy**. A plan is not a promise unless saved with `-out`, which is how
CI pipelines guarantee that what was reviewed is what runs.

---

## 4. AWS networking concepts

### The building blocks

- **VPC** — a private network you own, defined by a CIDR block (`10.20.0.0/16`,
  giving 65,536 addresses). Nothing enters or leaves unless routed and allowed.
- **Availability Zone** — an isolated group of data centres inside a region. Two
  minimum here, because an ALB requires two and an RDS subnet group requires two.
  AZ *names* map to different physical zones in different accounts, which is why
  the code asks AWS for them rather than hard-coding `us-east-1a`.
- **Subnet** — a slice of the VPC inside exactly one AZ. AWS reserves 5 addresses
  in every subnet, so a /24 gives 251 usable.
- **Route table** — where traffic goes. A subnet is *public* only because its
  route table sends `0.0.0.0/0` to an **internet gateway**.
- **Internet gateway** — the VPC's door to the internet. Free.
- **NAT gateway** — outbound-only access for private subnets. ~$33/month plus
  $0.045/GB, billed whether used or not. Hence the `enable_nat` switch.
- **VPC endpoint** — a private path to an AWS service.
  *Gateway* endpoints (S3, DynamoDB) are **free** and work via route tables.
  *Interface* endpoints cost ~$7.30/month per AZ each.

### The three-tier layout and why

```
Internet
   │ 443/80
┌──▼──────────── VPC 10.20.0.0/16 ─────────────────┐
│ public   .0  .1     [ALB]   [NAT, when enabled]  │
│ app      .10 .11    [ECS tasks]      private     │
│ data     .20 .21    [RDS]  no internet route     │
└──────────────────────────────────────────────────┘
```

Each tier only accepts traffic from the tier in front of it. The data tier's
route table has no `0.0.0.0/0` entry at all, so even a misconfigured security
group cannot give the database a path to the internet. That is defence in depth:
two independent controls must both fail before exposure.

### Security groups

- Attached to resources, **stateful** (a reply to an allowed request is allowed
  back automatically), **allow-only** (no deny rules).
- Written as separate rule resources
  (`aws_vpc_security_group_ingress_rule`) rather than inline blocks, so each rule
  has its own identity, its own `description`, and can change without rewriting
  the group.
- **Referencing another security group** instead of a CIDR is the important
  pattern: `app` accepts 8000 from `alb`; `db` accepts 5432 from `app`. It keeps
  working as container IPs change, and it cannot be satisfied from outside.
- The `db` group has **no egress rule**: a database has no reason to open
  connections outward.

`0.0.0.0/0` on the ALB's 80/443 is correct — that is a public website's front
door. The same rule on 5432 would be a serious mistake, because it lets any host
on the internet attempt authentication against the database, and exposes it to
unpatched Postgres vulnerabilities. Public entry belongs at exactly one place.

### Security groups vs network ACLs

| | Security group | Network ACL |
|---|---|---|
| Attached to | a resource | a subnet |
| State | stateful | stateless (need explicit return rules) |
| Rules | allow only | allow and deny |
| Evaluated | all rules together | in numbered order |

The default NACL allows everything; we rely on security groups plus routing.

---

## 5. Cost decisions

| Option for private outbound access | Always-on | Notes |
|---|---|---|
| One NAT gateway | ~$33/mo + $0.045/GB | standard, single AZ = single point of failure |
| Interface endpoints (ECR api, ECR dkr, logs, secrets) × 2 AZ | ~$58/mo | most private, more expensive at this size |
| Tasks in public subnets with public IPs | ~$3.65/mo per task | cheapest, least defence in depth |

**Chosen:** private subnets with a NAT gateway behind `enable_nat`, switched on
only while working, plus the free S3 gateway endpoint so ECR image layers (stored
in S3) never cross NAT and never incur per-GB charges.

Other prices worth memorising: public IPv4 address $0.005/hour (~$3.65/month)
each, ALB ~$16/month plus capacity units, EKS control plane ~$73/month.

---

## 6. Troubleshooting log

| Symptom | Cause | Fix | Principle |
|---|---|---|---|
| `Error: No valid credential sources found` … `login session has expired` | `aws login` sessions last up to 12h | `aws login --profile novatech` | Short-lived credentials expire by design; that is the point |
| `get-caller-identity` shows `:root` after logging in | `aws login` adopts whatever identity the browser is signed in as | Sign root out of the browser, sign in as `Dee`, log in again | Keep root in a separate browser, or use a private window |
| "Profile is already configured to use session …root. Overwrite? (y/n)" answered `n` | Kept the stale root session | Re-run and answer `y` | Read the prompt: it names the identity it will use |
| `terraform plan` failed before authenticating | Ran the command in the same block as the login | Authenticate, then plan | Run interactive commands on their own |
| `git`: cannot remove `.git/index.lock` | A git process was interrupted and left the lock | `rm .git/index.lock` | Only ever delete a lock when no git process is running |
| Imported `aws_ecr_lifecycle_policy` showed "must be replaced — will destroy the imported resource" | The rule description in code differed from the live policy, and any policy change forces replacement for that resource | Edited the code to match the live wording, re-planned | **After an import, make the code match reality first. The first apply should change nothing.** |
| `aws_ecr_repository` showed `~ tags_all` adding three tags | `default_tags` labelling a resource created by hand | Applied; harmless | Expect a small diff when adopting hand-made resources |
| `terraform fmt -check` failing | Formatting drift | `terraform fmt` | Keep it in CI so diffs stay about substance |

---

## 7. Interview questions

**Q: What is Terraform state and why does it matter?**
It maps configuration addresses to real resource IDs, and records the attributes
last seen. Without it Terraform cannot tell "already exists" from "needs
creating", so it plans duplicates. It can contain secrets, so it is never in git;
it lives in a private encrypted versioned bucket with locking, so concurrent runs
cannot corrupt it.

**Q: Someone deleted the state file. What do you do?**
Nothing is gone in AWS, and it is all still billing. Restore from the bucket's
version history if possible. Otherwise write `import` blocks for each resource,
plan until the diff is empty, then carry on. Never hand-delete resources to make
the plan look clean.

**Q: Why store state in S3 rather than in the repository?**
Secrets in plain text, merge conflicts on a machine-generated file, no locking,
and no shared source of truth for CI. S3 gives versioning, encryption, access
control and, since Terraform 1.10, native locking.

**Q: Explain public versus private subnets.**
A subnet is public only if its route table routes `0.0.0.0/0` to an internet
gateway. Private subnets have no such route; outbound-only access comes from a
NAT gateway in a public subnet. Our data subnets have no default route at all.

**Q: How do you let a private service reach AWS APIs without a NAT gateway?**
VPC endpoints. Gateway endpoints for S3 and DynamoDB are free and route-table
based; interface endpoints for other services cost per endpoint per AZ. At small
scale one NAT can be cheaper than four interface endpoints; at large data volumes
the reverse is true because NAT charges per GB.

**Q: Security group or NACL?**
Security groups are stateful, resource-attached, allow-only, and can reference
other security groups — that is where almost all access control belongs. NACLs
are stateless subnet-level filters with deny rules, used for coarse blocks such
as banning an IP range.

**Q: Why reference a security group instead of a CIDR?**
Container and instance IPs change constantly. Referencing the group expresses the
intent ("only the load balancer may reach the app") and keeps working through
scaling and replacement.

**Q: When is `0.0.0.0/0` acceptable?**
On the public entry point of a public service — an ALB's 80/443 — and on outbound
rules. Never on database ports, admin ports (22, 3389) or internal APIs.

**Q: `count` or `for_each`?**
`count` for a fixed number of identical things; `for_each` when the collection
can change, because it keys resources by a stable name and avoids the index shift
that destroys and recreates everything after a removal.

**Q: How do you bring hand-built resources under Terraform?**
Write the resource to match reality, add an `import` block with the resource's
ID, plan until the only diffs are ones you intend, apply, then delete the import
block. This is also the recovery path for lost state.

**Q: How do you keep a dev environment cheap?**
Tag everything, put always-on costs behind switches (`enable_nat`), use free
gateway endpoints, set budgets with alerts, and destroy what is not in use.
Terraform makes destroy-and-recreate cheap, which is what makes that practical.

---

## 8. Command reference

```bash
# identity
aws sts get-caller-identity              # who am I: expect user/Dee, UserId AIDA...
aws login --profile novatech             # refresh short-lived credentials
aws logout                               # drop the session
aws configure list                       # shows where credentials come from

# terraform core loop
terraform init                           # download providers, configure backend
terraform init -migrate-state            # move state to a newly configured backend
terraform fmt                            # canonical formatting
terraform validate                       # syntax and type checks (no AWS calls)
terraform plan                           # preview; changes nothing
terraform plan -out=tf.plan              # save the exact plan
terraform apply tf.plan                  # apply exactly what was reviewed
terraform apply -var="enable_nat=true"   # override a variable for one run
terraform output                         # all outputs
terraform output -raw state_bucket       # one output, unquoted, for scripts
terraform state list                     # what Terraform believes it manages
terraform destroy                        # remove everything in this stack

# verification
aws s3 ls s3://novatech-tfstate-253490749032-us-east-1/bootstrap/
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=novatech-dev-data" \
  --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,Target:GatewayId}' \
  --output table
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=novatech-dev-*" \
  --query 'SecurityGroups[].{Name:GroupName,Ingress:IpPermissions[].FromPort}'
```

---

## 9. Milestones reached

- Terraform installed; state stored remotely, encrypted, versioned and locked.
- A three-tier VPC across two AZs exists entirely as code, reviewed as a plan.
- The database tier has no route to the internet, proven by inspection.
- Access between tiers is expressed by security group references, not IP ranges.
- The hand-built ECR repository is now managed by Terraform via `import`.
- Always-on cost of the environment: about $0.

## 10. Known gaps, to close later

- No RDS, no ECS, no ALB yet — the network is empty.
- NAT is off; it must be switched on before private tasks can pull images, or
  replaced by interface endpoints.
- No HTTPS certificate yet (ACM), so the ALB listener story is incomplete.
- No VPC flow logs, no CloudTrail trail, no GuardDuty.
- No CI: `fmt`, `validate` and `plan` should run on every pull request.
- Default security group of the VPC is untouched; it should be emptied.
- Secrets handling for the database password is still to be designed — it must
  never appear in a `.tfvars` file, in state read by humans, or in git.
