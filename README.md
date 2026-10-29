# DevSecOps Home Test

A DevSecOps workflow for a containerized backend API on AWS. Security gates detect problems early and **block unsafe
releases automatically**. The deliverable is the codebase and its documentation: **no real AWS account, SonarCloud or
GitHub code scanning is connected**, and every AWS account ID is a fictitious demo value (see
[Known limitations](#6-known-limitations-and-remaining-risks)).

| Task | Where |
|---|---|
| 1. Architecture and security design | [`architecture/explanation.md`](architecture/explanation.md), [`architecture-diagram.png`](architecture/architecture-diagram.png) |
| 2. CI/CD security pipeline | [`.github/workflows/`](.github/workflows/), [`security/pipeline-security-gates.md`](security/pipeline-security-gates.md) |
| 3. Terraform and IAM | [`terraform/`](terraform/), [`terraform/README.md`](terraform/README.md) (includes Scenarios A, B, C) |
| 4. Container and application | [`app/Dockerfile`](app/Dockerfile), [`security/vulnerability-policy.md`](security/vulnerability-policy.md) |
| 5. Troubleshooting and incident response | [`security/incident-response.md`](security/incident-response.md) |
| 6. DAST and OWASP Top 10 | [`security/dast-and-owasp.md`](security/dast-and-owasp.md) |
| Scan evidence | [`evidence/scan-results.md`](evidence/scan-results.md) |

## 1. Architecture overview

![Architecture](architecture/architecture-diagram.png)

- **Request flow:** internet → AWS WAF → public ALB (HTTPS, TLS 1.2+) → ECS Fargate tasks in private subnets → RDS
  PostgreSQL in private data subnets. Only the ALB accepts inbound internet traffic.
- **Accounts:** an AWS Organization with a shared tooling account (ECR), a log-archive account (CloudTrail with Object
  Lock), and one workload account each for dev, staging and prod, all built from the same Terraform.
- **Network:** public, private app and private data subnets across 2 AZs in `ap-southeast-3` (Jakarta). NAT gateways for
  egress (one per AZ in prod), a free S3 gateway endpoint, DNS Firewall allow-list, VPC Flow Logs. The data subnets have no
  route out.
- **Secrets:** the app has **no secret**. It connects to the database with IAM database authentication as a least-privilege
  `app_user`. The RDS master password is generated and rotated by RDS in Secrets Manager and never appears in Terraform state.
- **Identity:** GitHub Actions gets short-lived AWS sessions through OIDC. No stored AWS keys. Separate roles for image
  push, plan, and deploy (one per environment account, each trusting only its GitHub Environment).
- **Encryption:** customer-managed KMS keys everywhere except ALB access logs (SSE-S3 only, a service limitation).

Full detail, the IAM role table and the risk register (11 risks) are in [`architecture/explanation.md`](architecture/explanation.md).

## 2. Prerequisites and how to run

Locally (macOS or Linux):

| Tool | Version used | Purpose |
|---|---|---|
| Go | 1.27.3 | build and test the app |
| Docker | recent | build the image, run ZAP |
| Terraform | >= 1.15 (CI pins 1.17.1) | validate IaC |
| Trivy | 0.76.1 | SCA, IaC and image scans |
| Gitleaks | 8.30.1 | secret scan |
| jq | any | gate scripts |

```bash
cd app && go test -race ./...                 # unit tests
docker build --tag devsecops-api:local app     # build the image
docker run --rm -p 127.0.0.1:8080:8080 --read-only --cap-drop ALL devsecops-api:local   # in-memory mode, no database needed
```

To run the pipeline for real, push to a GitHub repository. Without further configuration it runs every scan, and the AWS
steps (plan scan, image push, deploy) **run as simulations**. Setup details are in
[`security/pipeline-security-gates.md`](security/pipeline-security-gates.md#github-configuration).

## 3. CI/CD workflow and security gates

[`security-pipeline.yml`](.github/workflows/security-pipeline.yml) runs on every pull request and push to `main`, plus a
nightly re-scan. Release jobs run only on `main` and only if every gate passed.

| # | Stage | Tool | Blocks when |
|---|---|---|---|
| 1 | Source validation | Go tests, `terraform fmt/validate` | any failure |
| 2 | Secret scan | Gitleaks, full git history | any secret |
| 3 | SAST | SonarCloud | quality gate fails (new code) |
| 4 | SCA | Trivy | Critical, or High (see policy) |
| 5 | IaC scan | Trivy (+ plan JSON and `iam-wildcard-gate.sh` when a plan exists) | Critical/High misconfiguration, admin-style IAM |
| 6 | Docker build | Docker, SBOM | build failure |
| 7 | Container scan | Trivy (vulnerabilities and secrets) | Critical, or High (see policy) |
| 8 | DAST | OWASP ZAP | High alert |
| 9 | Deploy | GitHub Environments + OIDC | `production` needs reviewer approval; simulation without AWS |

- **Lower severities:** an untriaged **Medium** never fails the build but labels the pull request and requests a second
  engineer's review. **Low** is reported and tracked.
- **False positives and accepted risks:** only through a time-boxed entry (owner, reason, compensating control, expiry)
  in `.trivyignore.yaml` or `.zap/rules.tsv`, approved by the security team through CODEOWNERS. A finding that has a fix,
  or is on CISA KEV, can never be excepted. Details: [`security/vulnerability-policy.md`](security/vulnerability-policy.md).
- **Hardening:** actions pinned by commit SHA, scanner binaries pinned and checksum-verified, least-privilege job
  permissions, only the plan-scan job can request an OIDC token, secrets never printed.

## 4. Security decisions and assumptions

- **GitHub Actions + OIDC** instead of Jenkins: no self-hosting, no stored AWS keys, auditable run history.
- **SonarCloud** (managed) for SAST instead of a self-hosted SonarQube: less attack surface to patch and expose.
- **Trivy** for SCA, IaC and container scanning (Checkov dropped deliberately to reduce supply-chain surface); **Gitleaks** for
  secrets; **ZAP** for DAST.
- **ECS Fargate** over EKS: no nodes to patch, a clear split between the execution role and the task role.
- **No application secret** (IAM database authentication), so there is nothing to leak or rotate. Order of preference for
  any credential: none, AWS-managed rotation, automated rotation, scheduled manual rotation.
- **One account per environment** for the strongest isolation, with SCP guardrails.
- **Egress:** NAT gateway filtered by security groups, DNS Firewall and flow logs, instead of endpoints only.
- **Assumptions:** the demo account IDs, domain and certificate ARN are fictitious; Terraform is validated, scanned and
  (when credentials exist) planned, **never applied**; the app is a minimal Go API whose job is to give the gates something real
  to scan; Go and tool versions are pinned and bumped through Dependabot.

## 5. Validate Terraform and scan the container

```bash
# Terraform: format, validate (both roots)
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false -lockfile=readonly && terraform -chdir=terraform validate
terraform -chdir=terraform/tooling init -backend=false -lockfile=readonly && terraform -chdir=terraform/tooling validate

# IaC scan, evaluated with the prod variables, then apply the policy gate
trivy config . --skip-dirs terraform/.terraform,terraform/tooling/.terraform,evidence/scenarios \
  --ignorefile .trivyignore.yaml --tf-vars terraform/environments/prod.tfvars \
  --format json --output reports/trivy-iac.json
scripts/ci/trivy-gate.sh reports/trivy-iac.json

# Container scan
docker build --tag devsecops-api:local app
trivy image devsecops-api:local --scanners vuln,secret --ignorefile .trivyignore.yaml \
  --format json --output reports/trivy-image.json
scripts/ci/trivy-gate.sh reports/trivy-image.json

# Secret scan
gitleaks dir . --config .gitleaks.toml --redact
```

The full command set, including SCA, SBOM and ZAP, is in [`evidence/scan-results.md`](evidence/scan-results.md).

## 6. Known limitations and remaining risks

- **Nothing runs against real services.** SonarCloud, GitHub code scanning and AWS are not connected, so the SAST gate,
  plan scan and deployment have never executed. Blocking behaviour is shown with local gate runs on unsafe examples, not a
  failing pull request.
- **Terraform was never planned or applied.** It validates and passes the static scan, but provider-level errors (for example
  region-specific details in the opt-in region `ap-southeast-3`) can still appear at plan time.
- **Trivy does not flag `Action: "*"` on `Resource: "*"`** (its check is deprecated). `scripts/ci/iam-wildcard-gate.sh` covers it,
  but only on a plan, so before a plan exists the control is code review and SCPs.
- **The workflows were checked by YAML parsing and review only**: actionlint was not run.
- **The RDS CA bundle is not in the image yet**, which `sslmode=verify-full` needs.
- **DAST scope:** the sample API has no authentication, so the authenticated scan is a plan, not a demonstration.
- **One Low finding is accepted:** ZAP reports a missing `Cross-Origin-Resource-Policy` header (tracked).
- **Terraform state** is out of scope (nothing is applied); a real deployment needs an S3 backend with KMS, versioning and locking.
- **DNS Firewall can be bypassed** by connecting directly to an IP. AWS Network Firewall is the upgrade path.
- **Single region, no disaster recovery;** ALB-to-task traffic is plain HTTP inside the VPC.
- **SCPs, the organization CloudTrail and the OIDC bootstrap** are described, not coded.

## 7. Evidence of tests and scans

Run locally on 2026-10-29 with the same scanner versions the pipeline pins. Full output is in
[`evidence/`](evidence/).

| Control | Result |
|---|---|
| Unit tests | Pass |
| Gitleaks | 0 leaks |
| SCA (Trivy) | 2 High CVEs in `golang.org/x/text` **blocked**, fixed, then pass |
| Container scan | Same 2 High **blocked**, rebuilt image clean; 0 secrets; image 5.6 MB, non-root |
| IaC scan | `terraform/`: 0 Critical/High; Dockerfile: 1 Low (no `HEALTHCHECK`, intentional: distroless) |
| Unsafe IaC (Scenarios A, B) | Public, unencrypted database **blocked** (2 High); `Action:*` policy **blocked** by the wildcard gate |
| DAST (ZAP API scan) | 0 High, 0 Medium, 1 Low, 2 Info: passes |
| SBOM | CycloneDX, 31 components |

No AWS keys, passwords or tokens are in this repository. Reports contain no secrets, local paths or hostnames.
