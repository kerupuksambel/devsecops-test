#!/usr/bin/env bash
# Apply security/vulnerability-policy.md to a Trivy JSON report (vuln, secret or config scan).
#
#   Critical / High  -> fail the job, unless covered by an approved, unexpired
#                       exception in .trivyignore.yaml (Trivy drops those from the report).
#   Medium           -> never fails; counted and passed to the review-flag job.
#   Low              -> reported only.
#   Any secret       -> fail.
#
# For each blocking High it also says whether an exception is even allowed:
# a High with a fixed version, or one on the CISA KEV list, must be fixed, not excepted.
#
# Usage: trivy-gate.sh <trivy-report.json> [cisa-kev.json]
set -euo pipefail

report=$1
kev_file=${2:-}

kev='[]'
if [[ -n "$kev_file" && -s "$kev_file" ]]; then
  kev=$(jq -c '[.vulnerabilities[].cveID]' "$kev_file")
fi

summary=$(jq -c --argjson kev "$kev" '
  [.Results[]? | .Vulnerabilities[]?] as $v
  | [.Results[]? | .Misconfigurations[]? | select(.Status == "FAIL")] as $m
  | [.Results[]? | .Secrets[]?] as $s
  | ($v + $m) as $all
  | {
      critical: [$all[] | select(.Severity == "CRITICAL")] | length,
      high: [$all[] | select(.Severity == "HIGH")] | length,
      medium: [$all[] | select(.Severity == "MEDIUM")] | length,
      low: [$all[] | select(.Severity == "LOW")] | length,
      secrets: $s | length,
      blocking: [
        ($all[] | select(.Severity == "CRITICAL" or .Severity == "HIGH")
          | { id: (.VulnerabilityID // .ID), severity: .Severity,
              target: (.PkgName // .CauseMetadata.Resource // "-"),
              # Misconfigurations can always be fixed in code; vulnerabilities only when
              # a fixed version exists or the CVE is actively exploited (KEV).
              must_fix: (if .VulnerabilityID == null then true
                         else (.FixedVersion // "") != "" or (.VulnerabilityID as $id | $kev | index($id)) != null end) }),
        ($s[] | { id: .RuleID, severity: "SECRET", target: .Title, must_fix: true })
      ]
    }' "$report")

read -r critical high medium low secrets < <(jq -r '[.critical, .high, .medium, .low, .secrets] | @tsv' <<<"$summary")

{
  echo "### Trivy policy: \`$(basename "$report")\`"
  echo "| Critical | High | Medium | Low | Secrets |"
  echo "|---|---|---|---|---|"
  echo "| $critical | $high | $medium | $low | $secrets |"
  if [[ $((critical + high + secrets)) -gt 0 ]]; then
    echo
    echo "| Finding | Severity | Target | Exception allowed? |"
    echo "|---|---|---|---|"
    jq -r '.blocking[] | "| \(.id) | \(.severity) | \(.target) | \(if .must_fix then "No: must be fixed (fix available, actively exploited, or misconfiguration)" else "Yes, time-boxed, with security approval" end) |"' <<<"$summary"
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# Accumulate across repeated calls in the same step (e.g. static scan + plan scan).
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  prev=$(sed -n 's/^medium=\([0-9][0-9]*\)$/\1/p' "$GITHUB_OUTPUT" | tail -1)
  echo "medium=$(( ${prev:-0} + medium ))" >> "$GITHUB_OUTPUT"
fi

if [[ $((critical + high + secrets)) -gt 0 ]]; then
  echo "::error::Blocked by policy: $critical critical, $high high, $secrets secret finding(s). See the job summary."
  exit 1
fi
echo "Policy passed: no Critical/High findings or secrets ($medium medium flagged for review)."
