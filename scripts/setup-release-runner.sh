#!/bin/bash
# Explicit operator-only setup. Never invoked by the workflow or the release script.
set -euo pipefail
set +x
umask 077
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'The release runner requires macOS on Apple Silicon.' >&2; exit 1
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
repository="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repository"])' "$script_dir/../release/config.json")"
runner_dir="${ORBIT_RUNNER_DIRECTORY:-$HOME/Library/OrbitReleaseRunner}"
command -v gh >/dev/null
command -v python3 >/dev/null
# Registration requires admin rights on this exact repository, never a fork.
owner="$(gh api user --jq .login)"
expected_owner="${repository%%/*}"
if [[ "$owner" != "$expected_owner" ]]; then
  echo "Authenticate gh as the repository owner $expected_owner before registering." >&2; exit 1
fi
if [[ -e "$runner_dir/.runner" ]]; then
  echo 'This runner is already configured; no registration changed.' >&2; exit 1
fi
mkdir -p "$runner_dir"
metadata="$(mktemp -d /tmp/orbit-runner-setup.XXXXXX)"
trap 'unset ACTIONS_RUNNER_INPUT_TOKEN; rm -rf "$metadata"' EXIT
# GitHub asset digests authenticate the selected official ARM64 runner archive.
gh api repos/actions/runner/releases/latest > "$metadata/release.json"
python3 - "$metadata/release.json" > "$metadata/asset" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1]))
assets = [a for a in release['assets'] if re.fullmatch(r'actions-runner-osx-arm64-[0-9.]+\.tar\.gz', a['name'])]
if len(assets) != 1 or not (assets[0].get('digest') or '').startswith('sha256:'):
    raise SystemExit('Official runner asset or SHA-256 missing')
a = assets[0]
print(a['name']); print(a['digest'][7:]); print(release['tag_name'])
PY
asset="$(sed -n '1p' "$metadata/asset")"
digest="$(sed -n '2p' "$metadata/asset")"
tag="$(sed -n '3p' "$metadata/asset")"
gh release download "$tag" --repo actions/runner --pattern "$asset" --dir "$metadata"
printf '%s  %s\n' "$digest" "$metadata/$asset" | shasum -a 256 -c -
tar -xzf "$metadata/$asset" -C "$runner_dir"
# The runner accepts ACTIONS_RUNNER_INPUT_TOKEN; keep the token out of argv and logs.
ACTIONS_RUNNER_INPUT_TOKEN="$(gh api --method POST "repos/$repository/actions/runners/registration-token" --jq .token)"
export ACTIONS_RUNNER_INPUT_TOKEN
cd "$runner_dir"
./config.sh --unattended --url "https://github.com/$repository" \
  --name "orbit-release-$(scutil --get LocalHostName)" --labels orbit-release \
  --work _work
unset ACTIONS_RUNNER_INPUT_TOKEN
# The runner registers its default self-hosted/macOS/ARM64 labels as well.
./svc.sh install
./svc.sh start
