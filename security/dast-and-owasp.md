# DAST and OWASP Top 10 (Task 6)

DAST runs in the `dast` job of [`security-pipeline.yml`](../.github/workflows/security-pipeline.yml), using OWASP ZAP and the
policy script [`scripts/ci/zap-gate.sh`](../scripts/ci/zap-gate.sh). We test only our own application, started by the
pipeline, in an environment we control.

## 1. How the application is made available in a safe test environment

- The `build-image` job builds the image once. The `dast` job loads **that exact image** (the one that was scanned and will
  be released) and runs it on the CI runner, bound to `127.0.0.1` only.
- The container is hardened like production: read-only filesystem, all Linux capabilities dropped, `no-new-privileges`,
  non-root.
- It starts in **in-memory mode** (no `DB_HOST`): no database, no AWS credentials, no network path to AWS, and only
  fixed sample data. There is nothing real to read, corrupt or leak, and the job has no `id-token` permission.
- The runner is discarded after the job, so any state created by the scan disappears.
- For a deeper scan against a **deployed** environment, the target is the **staging** account only, reached through its
  own ALB, with synthetic data (never production data). See section 5.

## 2. Which DAST checks run automatically

- **ZAP API scan** (`zap-api-scan.py`) driven by the OpenAPI spec ([`app/api/openapi.yaml`](../app/api/openapi.yaml)), so every
  documented endpoint is exercised, not just whatever a crawler happens to find.
- ZAP's passive checks on every response (missing or weak security headers, cookies, information disclosure, caching
  of sensitive content, CORS) and its active checks on each operation (injection, path traversal, error disclosure, and others).
- The scan is **time-boxed** and the job has a 20-minute limit.
- Output: `zap.json` and `zap.html`, uploaded as the `report-dast` artifact (30 days) and summarized in the job summary.
- **Authentication:** see section 3.

## 3. Authentication during testing

The sample API is public and has no login, so the scan runs unauthenticated. For an API that requires a token, the plan is:

- A **dedicated test identity** in the test environment, with the least privileges needed to reach the endpoints under test,
  and **never** a production identity.
- A **short-lived token** created at job start (for example from the test environment's identity provider using a
  client-credentials grant, with a secret stored as a scoped GitHub Environment secret) and handed to ZAP as an
  `Authorization` header through a ZAP replacer rule, masked in logs (`::add-mask::`). It is never written to the
  repository, the report, or the artifact. The report is scanned for the token value before upload (to be added together with authentication).
- Both an authenticated and an unauthenticated pass: the second checks that protected endpoints really answer `401`/`403`
  (broken access control).
- Where roles exist, one pass per role, to detect horizontal and vertical privilege escalation.

## 4. Which findings block a release

| ZAP risk | Handling |
|---|---|
| **High** | **Blocks the release** (`zap-gate.sh` fails the job and `push-image` does not run) |
| **Medium** | Does not block. An untriaged Medium adds the `security-review-required` label to the pull request and requests a second engineer's review |
| **Low / Informational** | Reported and tracked only |

A triaged false positive is set to `IGNORE` in [`.zap/rules.tsv`](../.zap/rules.tsv) with an owner, reason and review
date, approved by the security team (CODEOWNERS); this keeps the review flag meaningful and is the only way a High is waived. The
rationale for the thresholds is in [`vulnerability-policy.md`](vulnerability-policy.md).

## 5. How testing is kept away from production

1. **Separate targets:** the pipeline only ever scans the container it started on the runner (and, if enabled, the staging
   environment). No production hostname appears in any workflow, spec file or variable. The spec's only server is
   `http://localhost:8080`.
2. **Account isolation:** staging and production are different AWS accounts. The DAST job has no AWS credentials, and the
   staging deploy role cannot be used against the production account.
3. **No production data:** the DAST target uses in-memory or synthetic data only.
4. **No active scanning of production.** In production, only non-intrusive monitoring runs: WAF (rate limiting and managed
   rule groups), GuardDuty, and a *passive*, read-only check of headers and TLS on a schedule if desired.
5. **Authorization:** ZAP is used only against systems we own and are authorized to test; in a shared or staging
   environment the scan window is announced, and the scan's source IP is allow-listed in WAF so scan traffic is
   distinguishable from real attacks.
6. **Guard against mistakes:** the target comes from the OpenAPI spec file, which CODEOWNERS assigns to the security reviewers, so changing the
   target requires their approval.

## OWASP Top 10 (2021) risks: detection and mitigation

| # | Risk | How it shows up here | Detection | Mitigation |
|---|---|---|---|---|
| **A01** | Broken Access Control | Another user reading items, a missing check on a new endpoint, unauthenticated access to protected routes | ZAP authenticated vs. unauthenticated passes; test suite cases for authorization; code review | Deny by default, authorization in middleware, least-privilege IAM and database user (`app_user`), ALB/WAF in front |
| **A02** | Cryptographic Failures | Plain HTTP, weak TLS, secrets in code or image layers, unencrypted data | ZAP (missing HSTS, mixed content), Gitleaks and Trivy secret scans, Trivy IaC (unencrypted storage) | HTTPS only with TLS 1.2+ at the ALB, `HSTS` header, KMS encryption at rest, RDS `rds.force_ssl`, no secrets in the repo or image |
| **A03** | Injection | SQL injection through a query parameter, command injection | SonarCloud SAST (taint analysis), ZAP active scan, WAF SQLi/Core rule sets | Parameterized queries only (`pgx` placeholders; the one current query takes no user input), input validation, request size limit (1 MiB), `app_user` has table-level privileges only |
| **A05** | Security Misconfiguration | Open security group, public database, verbose errors, missing headers, default accounts | Trivy IaC scan, ZAP passive header checks, plan scan | Hardened Terraform (see [`terraform/README.md`](../terraform/README.md)); the API returns `internal error` with no detail and sets CSP, `nosniff`, `X-Frame-Options` and `no-store` headers on every response; read-only, non-root container |
| **A06** | Vulnerable and Outdated Components | A dependency or base image with a known CVE | Trivy SCA and image scan (blocks High/Critical), ECR enhanced scanning, nightly re-scan, Dependabot | Pinned versions and image digests, fast patch deadlines by severity (see the vulnerability policy). This already caught two High CVEs in `golang.org/x/text` ([`evidence`](../evidence/scan-results.md)) |
| **A07** | Identification and Authentication Failures | Weak or absent authentication, long-lived credentials, credential stuffing | ZAP authenticated pass, WAF rate-based rule | No long-lived credentials: OIDC for CI, IAM roles and IAM database authentication for the app; rate limiting at WAF; MFA for human access |
| **A09** | Security Logging and Monitoring Failures | An attack goes unnoticed | Alarms and log review | Structured application logs (internal errors logged, not returned), WAF, ALB and VPC flow logs, CloudTrail in an Object-Lock archive account, GuardDuty |
| **A10** | Server-Side Request Forgery | The API fetches a user-supplied URL and reaches internal metadata or services | SAST, ZAP SSRF checks | The current API makes no outbound requests from user input. If it ever does, allow-list destinations; egress is restricted to 443 plus the DNS Firewall allow-list, and Fargate tasks have no instance metadata endpoint exposure beyond the task role |

The sample API is intentionally small (two read-only `GET` endpoints), so several risks are mitigated by design (no
state-changing endpoints, no user-supplied URLs, no session). The mapping above says where each control sits and which
stage would catch a regression.
