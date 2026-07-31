#!/usr/bin/env bash
set -euo pipefail

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
assets="$test_root/assets"
control="$test_root/control"
fake_bin="$test_root/bin"
remote="$test_root/remote"
runner="$test_root/runner"
state="$test_root/state"
mkdir -p "$assets" "$control" "$fake_bin" "$remote" "$runner"

cp .github/scripts/publish-client-release.sh "$control/"
cp .github/scripts/validate-release-evidence.py "$control/"
cat > "$control/manage-release.py" <<'PY'
#!/usr/bin/env python3
import sys

if len(sys.argv) < 2 or sys.argv[1] != "authorize":
    raise SystemExit("unexpected manager command")
PY
chmod +x "$control"/*

printf 'web bundle\n' > "$assets/camellia-remote-1.2.3-web.zip"
printf '{"spdxVersion":"SPDX-2.3"}\n' > "$assets/client.spdx.json"
printf '{"verificationMaterial":{}}\n' > "$assets/client.provenance.intoto.jsonl"
cat > "$assets/release-evidence.json" <<'JSON'
{
  "dependencies": [],
  "files": [
    {
      "architecture": "universal",
      "name": "camellia-remote-1.2.3-web.zip",
      "platform": "web",
      "provenance": {
        "name": "client.provenance.intoto.jsonl",
        "sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      },
      "sbom": {
        "name": "client.spdx.json",
        "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      },
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "signing": {
        "category": "not-applicable",
        "distribution": "not-applicable",
        "evidence": [],
        "timestamp": "not-applicable",
        "verification": "not-applicable",
        "verifier": "none"
      },
      "size_bytes": 1
    }
  ],
  "generated_at": "2026-07-31T00:00:00Z",
  "images": [],
  "policy": {
    "exceptions": [],
    "repository_policy_revision": "2026-07-31.1",
    "signing_registry_revision": "2026-07-31.1"
  },
  "release_kind": "formal",
  "repository": "remote-client",
  "schema_version": 1,
  "source": {
    "commit": "0123456789abcdef0123456789abcdef01234567",
    "ref": "refs/tags/v1.2.3",
    "validation_run_id": 42
  },
  "version": "1.2.3"
}
JSON
(
  cd "$assets"
  find . -maxdepth 1 -type f -printf '%f\n' |
    LC_ALL=C sort |
    xargs sha256sum > SHA256SUMS
)

cat > "$fake_bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  sign-blob)
    bundle=
    subject="${!#}"
    while (($#)); do
      if [[ "$1" == --bundle ]]; then
        bundle="$2"
        shift 2
      else
        shift
      fi
    done
    sha256sum "$subject" | awk '{print $1}' > "$bundle"
    ;;
  verify-blob)
    subject="$2"
    bundle=
    shift 2
    while (($#)); do
      if [[ "$1" == --bundle ]]; then
        bundle="$2"
        shift 2
      else
        shift
      fi
    done
    [[ "$(sha256sum "$subject" | awk '{print $1}')" == "$(cat "$bundle")" ]]
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$fake_bin/cosign"

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

release_json() {
  local draft=true immutable=false assets_json
  if [[ "$(cat "$FAKE_STATE")" == published ]]; then
    draft=false
    immutable=true
  fi
  assets_json="$(
    find "$FAKE_REMOTE" -maxdepth 1 -type f -printf '%f\n' |
      LC_ALL=C sort |
      jq -Rsc --arg uploader "$FAKE_UPLOADER" '
        split("\n")[:-1] |
        to_entries |
        map({
          id: (.key + 1),
          name: .value,
          uploader: {login: $uploader}
        })
      '
  )"
  jq -nc \
    --arg app "$FAKE_APP" \
    --arg sha "$FAKE_SHA" \
    --arg tag "$FAKE_TAG" \
    --arg title "$FAKE_TITLE" \
    --arg body "$FAKE_BODY" \
    --argjson assets "$assets_json" \
    --argjson draft "$draft" \
    --argjson immutable "$immutable" '{
      id: 17,
      tag_name: $tag,
      target_commitish: $sha,
      author: {login: $app},
      name: $title,
      body: $body,
      prerelease: false,
      draft: $draft,
      immutable: $immutable,
      assets: $assets
    }'
}

[[ "${GH_TOKEN:-}" == test-token ]]
case "$1" in
  api)
    shift
    route=
    while (($#)); do
      case "$1" in
        --paginate|--slurp)
          shift
          ;;
        -H|-X|--input)
          shift 2
          ;;
        *)
          route="$1"
          shift
          ;;
      esac
    done
    case "$route" in
      repos/test/repository/releases?per_page=100)
        release="$(release_json)"
        jq -nc --argjson release "$release" '[[$release]]'
        ;;
      repos/test/repository/releases/assets/*)
        asset_id="${route##*/}"
        name="$(
          find "$FAKE_REMOTE" -maxdepth 1 -type f -printf '%f\n' |
            LC_ALL=C sort |
            sed -n "${asset_id}p"
        )"
        [[ -n "$name" ]]
        cat "$FAKE_REMOTE/$name"
        ;;
      *)
        echo "Unexpected mock API route: $route" >&2
        exit 1
        ;;
    esac
    ;;
  release)
    operation="$2"
    tag="$3"
    shift 3
    [[ "$tag" == "$FAKE_TAG" ]]
    case "$operation" in
      upload)
        source="$1"
        cp "$source" "$FAKE_REMOTE/$(basename "$source")"
        ;;
      edit)
        [[ "$*" == *"--draft=false"* ]]
        printf 'published\n' > "$FAKE_STATE"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$fake_bin/gh"

export FAKE_APP='release-manager[bot]'
export FAKE_BODY=$'Release notes\n\n<!-- release-pr:7 -->\n<!-- release-commit:0123456789abcdef0123456789abcdef01234567 -->'
export FAKE_REMOTE="$remote"
export FAKE_SHA=0123456789abcdef0123456789abcdef01234567
export FAKE_STATE="$state"
export FAKE_TAG=v1.2.3
export FAKE_TITLE='Camellia Remote Client 1.2.3'
export FAKE_UPLOADER="$FAKE_APP"
printf 'draft\n' > "$state"

run_publisher() {
  PATH="$fake_bin:$PATH" \
  ACTIONS_TOKEN=actions-token \
  GH_TOKEN=test-token \
  GITHUB_REPOSITORY=test/repository \
  RELEASE_APP_LOGIN="$FAKE_APP" \
  RELEASE_ASSET_DIRECTORY="$assets" \
  RELEASE_COMMIT="$FAKE_SHA" \
  RELEASE_ID=17 \
  RELEASE_PR_NUMBER=7 \
  RELEASE_SIGNING_IDENTITY="https://github.com/test/repository/.github/workflows/publish-release.yml@refs/tags/v1.2.3" \
  RELEASE_TAG="$FAKE_TAG" \
  RELEASE_TITLE='Camellia Remote Client' \
  RUNNER_TEMP="$runner" \
  VERSION=1.2.3 \
    bash "$control/publish-client-release.sh"
}

run_publisher >/dev/null
[[ "$(cat "$state")" == published ]]
cmp "$assets/camellia-remote-1.2.3-web.zip" \
  "$remote/camellia-remote-1.2.3-web.zip"

VERIFY_PUBLISHED_ONLY=true run_publisher >/dev/null

printf 'tampered\n' > "$remote/camellia-remote-1.2.3-web.zip"
if VERIFY_PUBLISHED_ONLY=true run_publisher >/dev/null 2>&1; then
  echo "Publisher accepted modified immutable bytes" >&2
  exit 1
fi

echo "Managed client publication and recovery tests passed"
