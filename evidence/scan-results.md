# Scan Results (Execution Evidence)

**Date:** 2026-10-29. **Where:** locally, on the author's machine, with the **same scanner versions the
pipeline pins** (Trivy 0.76.1, Gitleaks 8.30.1). The same gate script the pipeline runs,
`scripts/ci/trivy-gate.sh`, evaluated each report against
[`security/vulnerability-policy.md`](../security/vulnerability-policy.md).

No external services were used. SonarCloud, GitHub code scanning and AWS are not connected (see
[Not covered here](#not-covered-here)). Raw reports are in [`raw/`](raw/), and contain no secrets,
local paths or hostnames.

## Summary

| Control | Tool | Target | Result | Gate |
|---|---|---|---|---|
| Secret scanning | Gitleaks 8.30.1 | All repository files | 0 leaks | ✅ Pass |
| SCA | Trivy `fs` | `app/go.mod` | **Before:** 2 High → **after fix:** 0 | ❌ Blocked → ✅ Pass |
| IaC scanning | Trivy `config` | Full `terraform/` (both roots, evaluated with `prod.tfvars`); `app/Dockerfile` | 0 Critical/High; 1 Low (Dockerfile) | ✅ Pass |
| IaC gate on unsafe input | Trivy `config`, `iam-wildcard-gate.sh` | `evidence/scenarios/` (public database; `Action:*` on `Resource:*`) | Scenario B: 2 High; Scenario A: wildcard policy | ❌ Blocked (as intended) |
| Container scanning | Trivy `image` (vulnerabilities + secrets) | `devsecops-api` image: distroless Debian 13.7 + Go binary | **Before:** 2 High → **after fix:** 0; 0 secrets | ❌ Blocked → ✅ Pass |
| DAST | OWASP ZAP 2.17.0, API scan from the OpenAPI spec | The built image, run read-only with all capabilities dropped | 0 High, 0 Medium, 1 Low, 2 Info; 119 rules passed | ✅ Pass |
| SBOM | Trivy `image --format cyclonedx` | Same image | 31 components | — |

## Finding: two High CVEs in a transitive dependency, blocked and fixed

The first scan of our own code found two vulnerabilities in `golang.org/x/text` v0.29.0. Nobody chose
this dependency directly: it is pulled in transitively by the PostgreSQL driver (`pgx`). It appeared both
in the dependency scan and in the compiled binary inside the image.

| CVE | Severity | Installed | Fixed in | Issue |
|---|---|---|---|---|
| CVE-2026-56851 | High | v0.29.0 | 0.41.0 | Denial of service: out-of-bounds slice in the Nickname profile |
| CVE-2026-56852 | High | v0.29.0 | 0.39.0 | Denial of service via invalid UTF-8 input |

**Gate decision** (from [`raw/gate-trivy-sca-before.md`](raw/gate-trivy-sca-before.md)):

```
::error::Blocked by policy: 0 critical, 2 high, 0 secret finding(s). See the job summary.

| Finding        | Severity | Target            | Exception allowed?                                                          |
|----------------|----------|-------------------|-----------------------------------------------------------------------------|
| CVE-2026-56851 | HIGH     | golang.org/x/text | No: must be fixed (fix available, actively exploited, or misconfiguration) |
| CVE-2026-56852 | HIGH     | golang.org/x/text | No: must be fixed (fix available, actively exploited, or misconfiguration) |
```

The gate blocked the release, and it ruled out an exception because a fixed version exists. This is
exactly the policy: a High with an available fix must be fixed, not excepted.

**Remediation:**

```bash
cd app
go get golang.org/x/text@v0.41.0   # fixes both CVEs
go mod tidy && go mod verify
go vet ./... && go test ./...      # still passing
```

**After the fix**, the dependency scan and the rebuilt image both report 0 vulnerabilities, and the gate
passes ([`raw/gate-trivy-sca-after.md`](raw/gate-trivy-sca-after.md),
[`raw/gate-trivy-image-after.md`](raw/gate-trivy-image-after.md)).

This is the case the pipeline exists for. The vulnerable version came in through a dependency's
dependency, nothing in the code looked wrong, and the tests passed. Only SCA and the image scan caught it.

## Finding: missing `HEALTHCHECK` in the Dockerfile (Low, accepted)

Trivy check DS-0026 recommends a `HEALTHCHECK` instruction. It is Low severity, so under the policy it is
reported and tracked but doesn't block. It is also intentionally not fixed:
- the runtime image is distroless, with no shell or `curl` to run a health command;
- in AWS, health is checked by the ALB target group against `/healthz`, and ECS replaces unhealthy tasks.

## Finding: Trivy does not catch `Action: *`, so a plan-based gate was added

Scenario A's policy (`Action: "*"`, `Resource: "*"`) was **not flagged** by Trivy 0.76.1: its wildcard check (AWS-0057) is
deprecated, and it gave no result even with `--include-deprecated-checks`. Rather than rely on it, `scripts/ci/iam-wildcard-gate.sh`
reads the resolved policies in the plan JSON and blocks admin-style statements. It blocks the PDF's policy
(`raw/gate-scenario-a.md`), passes a plan containing only read-only `Describe*` and an explicit deny, and blocks `s3:*` on `*`.
It runs in `iac-plan-scan`, so it needs a plan (real credentials); the gap before that is documented in
[`terraform/README.md`](../terraform/README.md).

## Scenario B: a public database is blocked

`evidence/scenarios/scenario-b/` holds a deliberately unsafe database (`publicly_accessible = true`, unencrypted, open to
`0.0.0.0/0`). The same gate the pipeline uses blocks it (`raw/gate-scenario-b.md`): `AWS-0180` and `AWS-0080` (High), plus 3 Medium and 1 Low.

## DAST: ZAP API scan of the running container

The image was run on a local Docker network (read-only filesystem, `--cap-drop ALL`, `no-new-privileges`, in-memory mode with
no database or credentials) and scanned with the pinned ZAP image (by digest) using `zap-api-scan.py` on
`app/api/openapi.yaml`. Locally ZAP reached the container by name (`-O http://api:8080`); the pipeline uses the runner's
host network.

| Alert | Risk | Handling |
|---|---|---|
| Cross-Origin-Resource-Policy header missing (90004) | Low | Tracked, not blocking. Possible hardening: send `Cross-Origin-Resource-Policy: same-origin` from `securityHeaders` |
| Client error response codes (100000) | Info | ZAP's own malformed probes; expected |
| Non-storable content (10049) | Info | Expected: the API sends `Cache-Control: no-store` |

`zap-gate.sh` passed: 0 High, 0 Medium ([`raw/gate-zap.md`](raw/gate-zap.md); full report in `raw/zap.json` and `raw/zap.html`).

## Other results

- **Base image:** the distroless `static-debian13` runtime layer had **0 OS-package vulnerabilities**.
  It contains no package manager or shell, so there is very little to be vulnerable.
- **Image hardening (verified):** the image runs as user `65532:65532` (non-root) and is 5.6 MB.
- **Terraform:** the full deployment (VPC, ALB, WAF, ECS, RDS, IAM, ECR) passes `terraform validate` and the Trivy scan
  with 0 Critical/High. Findings that are intentional carry an inline `#trivy:ignore` with the reason: the public ALB and its
  HTTPS rule, 443 egress for tasks, and ALB access logs (SSE-S3 only).

## Commands to reproduce

Run these from the repository root:

```bash
mkdir -p evidence/raw

# Secret scanning
gitleaks dir . --config .gitleaks.toml --redact \
  --report-format json --report-path evidence/raw/gitleaks.json --exit-code 1

# SCA
trivy fs app --scanners vuln --ignorefile .trivyignore.yaml \
  --format json --output evidence/raw/trivy-sca.json
scripts/ci/trivy-gate.sh evidence/raw/trivy-sca.json

# IaC (Terraform + Dockerfile)
trivy config . --skip-dirs terraform/.terraform,terraform/tooling/.terraform,evidence/scenarios \
  --ignorefile .trivyignore.yaml --tf-vars terraform/environments/prod.tfvars \
  --format json --output evidence/raw/trivy-iac.json
scripts/ci/trivy-gate.sh evidence/raw/trivy-iac.json

# Container image + SBOM
docker build --tag devsecops-api:local app
trivy image devsecops-api:local --scanners vuln,secret --ignorefile .trivyignore.yaml \
  --format json --output evidence/raw/trivy-image.json
scripts/ci/trivy-gate.sh evidence/raw/trivy-image.json
trivy image devsecops-api:local --format cyclonedx --output evidence/raw/sbom.cdx.json
```

Outside GitHub Actions, the gate script writes its summary table to stdout.

## Not covered here

| Control | Why | Where it is defined |
|---|---|---|
| SAST (SonarCloud) | Needs a SonarCloud account; no external services by design | `sast` job, `sonar-project.properties` |
| Terraform plan scan | Needs a real AWS account; the account IDs are fictitious | `iac-plan-scan` job |
| Workflow lint (actionlint) | Not installed locally; the workflows were checked by YAML parsing and review | `.github/workflows/` |

## Raw files

| File | Content |
|---|---|
| `gitleaks.json` | Gitleaks report (empty: no leaks) |
| `trivy-sca-before.json`, `gate-trivy-sca-before.md` | Dependency scan with the 2 High CVEs, and the gate's blocking decision |
| `trivy-sca-after.json`, `gate-trivy-sca-after.md` | Dependency scan after the fix; gate passes |
| `trivy-image-before.json`, `gate-trivy-image-before.md` | Image scan with the 2 High CVEs, and the blocking decision |
| `trivy-image-after.json`, `gate-trivy-image-after.md` | Rebuilt image after the fix; gate passes |
| `trivy-iac.json`, `gate-trivy-iac.md` | IaC scan: Terraform clean, 1 Low on the Dockerfile |
| `trivy-scenario-b.json`, `gate-scenario-a.md`, `gate-scenario-b.md` | Gate decisions for the unsafe Scenario A and B inputs |
| `zap.json`, `zap.html`, `gate-zap.md` | ZAP report and the gate decision |
| `sbom.cdx.json` | CycloneDX SBOM of the released image |
