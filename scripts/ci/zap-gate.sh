#!/usr/bin/env bash
# Apply the DAST policy to a ZAP JSON report.
#   High (riskcode 3)   -> fail the job.
#   Medium (riskcode 2) -> never fails; counted for the review-flag job.
#   Low / Info          -> reported only.
# Triaged false positives are set to IGNORE in .zap/rules.tsv, with a reason.
#
# Usage: zap-gate.sh <zap-report.json>
set -euo pipefail

report=$1

count() { jq --arg r "$1" '[.site[]?.alerts[]? | select(.riskcode == $r)] | length' "$report"; }
high=$(count 3)
medium=$(count 2)
low=$(count 1)
info=$(count 0)

{
  echo "### ZAP policy"
  echo "| High | Medium | Low | Info |"
  echo "|---|---|---|---|"
  echo "| $high | $medium | $low | $info |"
  echo
  echo "| Alert | Risk | Instances |"
  echo "|---|---|---|"
  jq -r '.site[]?.alerts[]? | "| \(.name) (\(.pluginid)) | \(.riskdesc) | \(.count) |"' "$report"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "medium=$medium" >> "$GITHUB_OUTPUT"

if [[ $high -gt 0 ]]; then
  echo "::error::Blocked by policy: $high High-risk DAST alert(s). See the job summary."
  exit 1
fi
echo "DAST policy passed ($medium medium flagged for review)."
