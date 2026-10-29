# Terraform

Two roots, because they deploy to different AWS accounts. Demo account IDs are fictitious. **Nothing is applied**: the
pipeline runs `fmt`, `validate` and a Trivy scan, and a plan only once real credentials are configured.

| Root | Account | Contents |
|---|---|---|
| `terraform/` | One per environment (dev `444…`, staging `555…`, prod `666…`) | VPC, ALB + WAF, ECS Fargate, RDS, KMS, flow logs, DNS Firewall, GitHub OIDC, `ci-deploy-<env>`, `ci-terraform-plan` |
| `terraform/tooling/` | Shared tooling `222…` | ECR (immutable tags, KMS, enhanced scanning), cross-account pull policy, GitHub OIDC, `ci-image-push` |

Environment separation: one account per environment, the same code, and a variable file each
(`environments/dev.tfvars`, `staging.tfvars`, `prod.tfvars`, `tooling.tfvars`). The variable files hold demo values only and no secrets.
Prod differs by Multi-AZ RDS, one NAT gateway per AZ, deletion protection, and more tasks.

## Requirement map

| PDF requirement | Where |
|---|---|
| Provider, scoped resources | `main.tf` (`allowed_account_ids` refuses any other account), `network.tf`, `alb.tf`, `ecs.tf`, `rds.tf` |
| IAM least privilege | `ecs.tf` (execution role: pull + own logs; task role: `rds-db:connect` as `app_user` only), `ci_iam.tf` (deploy role: one service, `PassRole` on two roles), `tooling/main.tf` (push to one repository) |
| Encryption at rest | Customer-managed KMS keys: log groups, RDS storage, Performance Insights, master secret, ECR. Exception: ALB access logs (SSE-S3 only, a service limitation) |
| Restricted network | Private app and data subnets, data tier has no route out, security groups chained ALB → tasks → RDS, task egress 443 only, DNS Firewall allow-list, flow logs |
| Secret handling | No application secret. RDS-managed master password (`manage_master_user_password`), IAM database authentication for the app |
| Tagging, environments | Provider `default_tags` (Project, Environment, ManagedBy, Owner, DataClass) |
| Automated IaC scanning | Trivy `config` on every change, the plan JSON when available, plus `scripts/ci/iam-wildcard-gate.sh` |

## Validate and scan

```bash
terraform -chdir=terraform init -backend=false -lockfile=readonly
terraform -chdir=terraform validate
terraform -chdir=terraform/tooling init -backend=false -lockfile=readonly
terraform -chdir=terraform/tooling validate
trivy config . --skip-dirs terraform/.terraform,terraform/tooling/.terraform,evidence/scenarios \
  --tf-vars terraform/environments/prod.tfvars
```

## Mandatory scenarios: remediation notes

The deliberately unsafe inputs are in [`evidence/scenarios/`](../evidence/scenarios/) (never deployed, excluded from the
pipeline scan) and the gate output is in [`evidence/raw/`](../evidence/raw/).

### Scenario A: `Action: "*"` on `Resource: "*"`

**Why it is dangerous.** It is full administrator access to the whole account. A leaked token, a compromised dependency or a
malicious pull request could create IAM users, read every secret and database, disable CloudTrail and GuardDuty, and delete
backups. Nothing limits the damage, and the audit trail itself is within reach.

**Safer approach (implemented):**

| Consideration | Implementation |
|---|---|
| Separate deploy and runtime roles | `ci-deploy-<env>` can only deploy. The task role is what the application runs as. The pipeline can deploy the app but cannot act as it |
| Resource-level permissions | `ecs:UpdateService` on the one service ARN; `rds-db:connect` on the one `app_user` ARN; ECR push on the one repository ARN |
| `iam:PassRole` bounded | Only the execution and task roles, with `iam:PassedToService = ecs-tasks.amazonaws.com` |
| Short-lived credentials | GitHub OIDC, one-hour sessions, no access keys, no stored secrets |
| Cross-account | One role per environment account, each trusting only `repo:<org>/<repo>:environment:<env>`. A dev job can never obtain prod credentials. ECR pulls are allowed only for each account's execution role |
| Guardrails | SCPs and permissions boundaries (design, `architecture/explanation.md`); IAM Access Analyzer finds unused permissions |

**Detection.** `scripts/ci/iam-wildcard-gate.sh` reads the resolved policies in the Terraform plan JSON and blocks any `Allow`
with a wildcard action on `Resource: "*"`. Trivy's own wildcard check (AWS-0057) is deprecated and, in testing, did not flag
this policy, so it is not relied on. Evidence: `evidence/raw/gate-scenario-a.md`. Limitation: the gate needs a plan, so
before a plan job is enabled the controls are code review of `.tf` changes (CODEOWNERS) and the SCPs.

### Scenario B: database reachable from `0.0.0.0/0`

**How the pipeline detects and blocks it.** The `iac-scan` job (on every pull request) runs Trivy over the `.tf` files and
the `iac-plan-scan` job runs it over the resolved plan. `scripts/ci/trivy-gate.sh` fails the job on any Critical or High
misconfiguration, and misconfigurations can never be excepted. Required status checks on `main` mean the merge, and so
the deployment, cannot proceed. Run against an example with a public, unencrypted database
(`evidence/scenarios/scenario-b/`), the gate **blocked it**: `AWS-0180` (publicly accessible, High) and `AWS-0080`
(unencrypted, High); it also reported Medium findings for the missing IAM authentication, backups and deletion protection.
Evidence: `evidence/raw/gate-scenario-b.md`.

**Second and third lines of defence.** The real design places RDS in subnets with no default route and no public
address, its security group accepts 5432 only from the task security group, and an SCP and a CloudWatch alarm cover
security group changes to `0.0.0.0/0`.

### Scenario C: password in Terraform variables and in state

**Prevent further exposure.**
1. **Remove the secret from the code path.** This repository has no database password variable. The master password uses
   `manage_master_user_password = true`: RDS generates it in Secrets Manager under our KMS key and rotates it, so Terraform
   never sees it and it never enters state. The application has no password at all (IAM authentication).
2. **Block recurrence.** Gitleaks scans the full history on every change, and Trivy flags `password` arguments in resources.
   Variables that could hold secrets are marked `sensitive`, and `*.tfvars` is git-ignored except the reviewed
   environment files, which contain no secrets.
3. **Protect state.** A real backend would be S3 in the tooling account with KMS, versioning, locking and read access
   limited to the plan and apply roles. The plan role explicitly denies `s3:GetObject`.

**Handle the credential already exposed.**
1. **Treat it as compromised and rotate it now**, in the database, before any cleanup. Check CloudTrail and database
   logs for use of the old value.
2. If it reached Git: rewrite history only as a cleanup step (it is not a fix, since clones and caches keep a copy), and
   assume it was read.
3. **Purge state:** move the resource to the managed-password setup, apply, and delete old state versions and any copies
   of plan files and CI artifacts that contain the value. Restrict who may read them.
4. Record the incident and add the detection that would have caught it (see `security/incident-response.md`).
