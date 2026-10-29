#!/usr/bin/env bash
# Download a release tarball, verify its SHA-256 before anything runs, and put the
# binary on PATH for later steps.
#
# Usage: install-tool.sh <binary-name> <tar.gz URL> <expected sha256>
set -euo pipefail

name=$1
url=$2
expected_sha=$3

dir="${RUNNER_TEMP:-/tmp}/tools"
mkdir -p "$dir/bin"
archive="$dir/$name.tar.gz"

curl -fsSL --proto '=https' --tlsv1.2 --output "$archive" "$url"
echo "$expected_sha  $archive" | sha256sum --check --strict

tar -xzf "$archive" -C "$dir/bin" "$name"
"$dir/bin/$name" --version
echo "$dir/bin" >> "$GITHUB_PATH"
