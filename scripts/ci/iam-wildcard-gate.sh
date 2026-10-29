#!/usr/bin/env bash
# Blocks administrator-style IAM policies: an Allow statement whose Action is "*" (or a bare
# service wildcard such as "iam:*") on Resource "*".
#
# Why a script: Trivy's own wildcard check (AWS-0057) is deprecated and does not evaluate policies
# built with jsonencode() or policy documents. A terraform plan JSON has every policy fully
# resolved, so this gate reads that instead. It also accepts a plain IAM policy JSON file.
#
# Usage: iam-wildcard-gate.sh <tfplan.json | policy.json>...
set -euo pipefail

status=0
for file in "$@"; do
  violations=$(jq -r '
    [ .. | strings | select(startswith("{") and contains("Statement"))
      | (try fromjson catch empty) | select(type == "object" and has("Statement")) ]
    + [ . | select(type == "object" and has("Statement")) ]
    | .[] | (.Statement | if type == "array" then . else [.] end)[]
    | select(.Effect == "Allow")
    | select([.Action // empty] | flatten | any(. == "*" or test("^[a-z0-9-]+:\\*$")))
    | select([.Resource // empty] | flatten | any(. == "*"))
    | "Action=\([.Action] | flatten | join(",")) Resource=\([.Resource] | flatten | join(","))"
  ' "$file" | sort -u)

  if [[ -n "$violations" ]]; then
    status=1
    echo "### IAM wildcard gate: \`$(basename "$file")\`"
    echo "$violations" | while read -r v; do echo "::error::Blocked: Allow statement is too broad ($v)"; done
  else
    echo "IAM wildcard gate passed for $(basename "$file"): no Allow statement combines a wildcard action with Resource \"*\"."
  fi
done
exit $status
