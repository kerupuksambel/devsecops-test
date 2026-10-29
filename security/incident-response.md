# Troubleshooting and Incident Response (Task 5)

Concise runbooks for the three scenarios. Each gives the investigation steps, likely root causes and corrective actions.
Account IDs and names are the fictitious demo values used across this repository.

---

## Scenario A: Trivy reports a Critical in the base image; the team wants an urgent release

**Position: the pipeline stays red, but the team gets a fast, safe path.** "The app works" says nothing about the
vulnerability. Nobody can waive a gate by asking; an exception follows the process in
[`vulnerability-policy.md`](vulnerability-policy.md).

### 1. Assess the risk (first 30 minutes)

| Question | How to answer |
|---|---|
| Is it real? | Read the finding: package, installed and fixed version, CVE. Check whether the package is in the final image or only in a build layer (our runtime is distroless, so most OS packages are absent) |
| Is it exploitable here? | Is the vulnerable code reachable from the API? Is the component exposed (network, input parsing)? Check the vendor advisory, EPSS and the **CISA KEV** list |
| What is the exposure? | Internet-facing API behind WAF, no shell in the image, read-only filesystem, non-root, egress limited to 443 and the DNS allow-list |
| Is it already in production? | The nightly re-scan and ECR enhanced scanning (Amazon Inspector) tell us whether the running image has the same finding. If it does, this is an incident, not just a blocked release |

### 2. Remediate (preferred, usually under a day)

1. **A fix exists:** bump the base image to the patched digest (Dependabot PR, or by hand), rebuild, re-scan, release. The
   image is pinned by digest, so this is one reviewed line.
2. **No fix in the current tag:** try a newer tag or a different minimal base (distroless `static` has far fewer packages
   than a full distribution), or remove the vulnerable package if the app does not use it.
3. **Application dependency vs. OS package:** if the Critical is in our Go dependencies, update `go.mod` (see the
   `golang.org/x/text` example in [`../evidence/scan-results.md`](../evidence/scan-results.md)).

### 3. Exceptions (only when no fix exists)

An exception is allowed only for a Critical or High that **has no patch and is not on CISA KEV**. A finding with a fix, or on
KEV, is never excepted: it must be fixed. If those conditions hold, the requester opens a pull request adding an entry to
`.trivyignore.yaml` with:

- the CVE and package path, so it is not a blanket ignore;
- the **owner, justification and compensating controls** (WAF rule, unreachable code path, disabled feature, network
  isolation);
- an **expiry date** (30 days for a Critical, then the gate fails again);
- approval from the security team through CODEOWNERS.

Every exception is reviewed again at expiry and tracked on the vulnerability list.

### 4. Release authorization

- **Normal path:** a clean pipeline on the patched image, then the usual promotion: dev → staging → production approval.
- **Emergency release** (a business-critical fix must ship while an exception is still pending): the approved exception
  above *is* the authorization. A named security approver and the service owner both sign off in the pull request; the
  `production` environment's required reviewers still approve the deployment. Nothing bypasses the gate, because the
  exception is recorded in the file the gate reads, with an expiry date.
- **Never:** disable the scan, lower the severity threshold, merge with the check red, or deploy a tag outside the pipeline.
  Required status checks and the deploy role's trust (only the `production` environment from `main`) make this technically
  impossible, not just against policy.

### 5. Afterwards

Record the decision and its expiry, verify the patched image in ECR enhanced scanning, and note why the vulnerable base was
not caught earlier (for example, a stale digest). If a Critical keeps recurring, shorten the Dependabot interval for base images.

---

## Scenario B: ECS task cannot retrieve a secret from Secrets Manager

**Note on this design.** The sample application deliberately has **no application secret**: it connects with IAM database
authentication. This runbook applies to any secret the service adds later (for example, a third-party API key) and to the
RDS master secret, which only the break-glass role may read. The investigation is the same.

### Key distinction: which role fetches the secret?

| How the secret is used | Role that needs access | Failure looks like |
|---|---|---|
| Injected by ECS through the container definition's `secrets` field, before the container starts | **Task execution role** (plus its KMS access) | The task **never starts**; stopped reason in ECS: `ResourceInitializationError: unable to pull secrets or registry auth` |
| Read by the application code at runtime through the SDK | **Task role** | The container starts, then the app logs `AccessDeniedException` |

The usual root cause is granting the permission to the wrong role.

### Investigation order (read-only; no administrator access needed)

1. **ECS task events and stopped reason.** `aws ecs describe-tasks` / the console's stopped-task message: it usually names
   the failing step and the API (`secretsmanager:GetSecretValue`, `kms:Decrypt`, or a timeout).
2. **CloudWatch Logs** for the service (`/ecs/devsecops-api-<env>`): the app's own error, or the absence of any log line,
   which points at the execution role or the network.
3. **CloudTrail:** filter on `GetSecretValue` and `Decrypt` for the role's session. `errorCode: AccessDenied` with the
   evaluated policy type shows whether an IAM policy, a resource policy, a permissions boundary or an SCP denied it. A
   missing event means the request never left the task (network).
4. **IAM Policy Simulator / `iam simulate-principal-policy`** for the exact role, action and secret ARN: it answers
   without changing anything.
5. **Check each layer:**
   - **Secret resource:** correct name, region (`ap-southeast-3`) and account? A secret in another account needs a
     resource policy as well as the role policy. A binding to the *partial* ARN with a suffix mismatch is common.
   - **Identity policy:** `secretsmanager:GetSecretValue` (and `DescribeSecret` if used) on that one secret ARN, on the right
     role.
   - **KMS:** if the secret uses a customer-managed key, the role needs `kms:Decrypt` on it **and** the key policy must allow
     the role (or delegate to IAM). The default `aws/secretsmanager` key is not shareable across accounts.
   - **Network:** tasks reach Secrets Manager's public endpoint through the **NAT gateway** (port 443). Check the task
     security group egress (443), the private route table's default route to a healthy NAT gateway, and the
     **DNS Firewall**: `secretsmanager.ap-southeast-3.amazonaws.com` is covered by the `*.amazonaws.com.` allow rule, but a
     custom or cross-region name would be blocked and return `NXDOMAIN`. The VPC Flow Logs and the DNS query logs show
     rejected traffic. (A VPC interface endpoint, if added later, also needs its own policy and security group.)
   - **Guardrails:** an SCP or permissions boundary denying `secretsmanager:*` outside the allow-listed region.

### Isolate without broad permissions

Never "fix" this by attaching `AdministratorAccess` or `secretsmanager:*` on `*`. Instead:

- reproduce with a **one-off task** (same task definition) in the same subnets and security group, where the failure is
  observable and the production service is untouched;
- use the **policy simulator** and CloudTrail errors to name the single missing permission, then add exactly that action on
  that ARN (plus the KMS grant), through a reviewed Terraform change;
- for a quick network test, run the check from a task in the same subnet rather than opening the security group wider.

### Corrective actions

Add the permission to the correct role through Terraform, or fix the key policy, route or DNS allow-list; redeploy. Add a
test or alarm (for example, a CloudWatch alarm on `AccessDenied` for the service's roles) so the next occurrence is found
by monitoring rather than by users.

---

## Scenario C: CloudTrail shows unexpected API calls from the deployment pipeline's IAM principal

Treat it as a real incident until proven otherwise. The pipeline roles are short-lived OIDC sessions, so this means either a
compromised GitHub workflow/token or an over-broad trust policy.

### 1. Contain (minutes)

1. **Revoke the sessions:** attach an inline `Deny *` policy with the condition `aws:TokenIssueTime` earlier than "now" on
   the affected role (the console's *Revoke active sessions*). This invalidates every session already issued without
   deleting the role. For the OIDC provider path, also change the role's trust policy to `Deny` / empty until cleared.
2. **Cut the entry point on the GitHub side:** disable the workflow or the environment, rotate the Dependabot/repository
   secrets that the same workflow can read (for example `SONAR_TOKEN`), and review recent runs, pull requests and branch
   protection changes. There are no AWS keys stored in CI/CD to rotate, which is the point of OIDC.
3. **Do not delete the evidence:** keep the logs. The organization CloudTrail in the log-archive account has Object Lock,
   so a compromised workload account cannot erase it.

### 2. Investigate

| Question | Source |
|---|---|
| What did the principal do, and from where? | CloudTrail event history and the org trail (Athena over the archive bucket): filter on `userIdentity.sessionContext.sessionIssuer` = the role; compare `sourceIPAddress`, `userAgent`, region and time with a normal pipeline run |
| Which workflow run assumed the role? | The `AssumeRoleWithWebIdentity` event records the token's `sub` (repository and environment) and the run's claims; match it against GitHub's workflow run history |
| Is the trust policy too broad? | Review the `sub` condition: is it pinned to `environment:<env>`? A wildcard like `repo:org/*` would be the root cause |
| What resources were touched? | Group the calls by service: `Describe*` only means reconnaissance; `PassRole`, `CreateRole`, `PutRolePolicy`, `CreateAccessKey`, `CreateUser`, `StopLogging`, `DeleteTrail`, KMS or `GetSecretValue` mean escalation or data access |
| Did it persist? | Look for new IAM users, access keys, roles, trust-policy changes, Lambda functions, security group changes, new ECS task definitions or images |
| Did the app or data change? | Compare the running task definition and image digest with the last pipeline-approved digest; check ECR for unexpected pushes; GuardDuty findings for the account |

The deploy role can only update one ECS service and pass two roles, so the blast radius is small by design: the likely
worst case is a malicious task definition (a different image) rolled to the service, which would be visible as an image
digest that never went through the pipeline.

### 3. Recover

1. Roll the service back to the last known-good, pipeline-approved image digest, and redeploy through the pipeline.
2. Remove anything the attacker created (roles, keys, task definitions); restore changed policies from Terraform
   (`terraform plan` shows the drift).
3. **Assume credentials or permissions may be compromised** when the activity went beyond the deploy role's permissions
   (privilege escalation): rotate the RDS master secret (and any third-party secret), re-issue anything the role could reach,
   and review break-glass role activity.
4. Fix the root cause: tighten the trust policy, pin actions by commit SHA (already done), reduce the workflow's permissions,
   require review for workflow-file changes (CODEOWNERS).

### 4. Audit and follow-up

- Preserve and hash the relevant CloudTrail, GitHub audit and workflow logs; write a timeline (first malicious event, entry
  point, impact, containment time).
- Notify the security owner, and the data-protection contact if any data may have been accessed.
- Add detection that would have caught it earlier: the existing alarm on `AssumeRole` of `ci-deploy-prod` outside a pipeline
  run, an alarm on any deploy-role call outside `ecs:*`, and GuardDuty `IAMUser/InstanceCredentialExfiltration`-style findings.
- Review for lessons learned in a blameless post-incident review within a week.
