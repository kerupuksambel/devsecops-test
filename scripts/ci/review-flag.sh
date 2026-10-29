#!/usr/bin/env bash
# Medium findings do not block, but they must not go unseen. If any scanner reported
# untriaged Medium findings, label the PR and request a review from the security team.
# Triaged findings live in .trivyignore.yaml / .zap/rules.tsv and are no longer counted,
# so only new (untriaged) Mediums raise the flag.
#
# Env: GH_TOKEN, PR_NUMBER, MEDIUM_SCA, MEDIUM_IAC, MEDIUM_PLAN, MEDIUM_IMAGE, MEDIUM_DAST,
#      SECURITY_REVIEWERS (org/team slug, optional)
set -euo pipefail

label="security-review-required"
total=$(( ${MEDIUM_SCA:-0} + ${MEDIUM_IAC:-0} + ${MEDIUM_PLAN:-0} + ${MEDIUM_IMAGE:-0} + ${MEDIUM_DAST:-0} ))

if [[ $total -eq 0 ]]; then
  echo "No untriaged Medium findings."
  gh pr edit "$PR_NUMBER" --remove-label "$label" 2>/dev/null || true
  exit 0
fi

gh label create "$label" --color D93F0B --description "Untriaged Medium security findings" --force
gh pr edit "$PR_NUMBER" --add-label "$label"
if [[ -n "${SECURITY_REVIEWERS:-}" ]]; then
  gh pr edit "$PR_NUMBER" --add-reviewer "$SECURITY_REVIEWERS"
fi

gh pr comment "$PR_NUMBER" --body-file - <<EOF
**Security review required:** $total untriaged Medium finding(s).

| Scanner | Medium |
|---|---|
| Dependencies (SCA) | ${MEDIUM_SCA:-0} |
| IaC (static) | ${MEDIUM_IAC:-0} |
| IaC (plan) | ${MEDIUM_PLAN:-0} |
| Container image | ${MEDIUM_IMAGE:-0} |
| DAST | ${MEDIUM_DAST:-0} |

Medium findings do not block the merge, but a second engineer must review them. Either fix them,
or triage them into \`.trivyignore.yaml\` / \`.zap/rules.tsv\` with an owner, reason and expiry date.
Fix deadline per policy: 30–90 days. Details are in the run's job summaries and artifacts.
EOF
