#!/usr/bin/env bash
set -euo pipefail

version="${1:?stable MAJOR.MINOR.PATCH version is required}"
build_number="${2:?positive Flutter build number is required}"
source_date_epoch="${3:-}"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "version must be stable SemVer MAJOR.MINOR.PATCH without a v prefix" >&2
  exit 2
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "build number must be a positive decimal integer" >&2
  exit 2
fi
if [[ -n "$source_date_epoch" && ! "$source_date_epoch" =~ ^[0-9]+$ ]]; then
  echo "source date epoch must be a non-negative decimal integer" >&2
  exit 2
fi

cargo_version="$version"
app_version="${version}+${build_number}"
if [[ -n "$source_date_epoch" ]]; then
  build_date="$(
    python3 - "$source_date_epoch" <<'PY'
import datetime
import sys

timestamp = int(sys.argv[1])
print(datetime.datetime.fromtimestamp(timestamp, datetime.UTC).strftime("%Y-%m-%d %H:%M UTC"))
PY
  )"
else
  build_date="$(date -u '+%Y-%m-%d %H:%M UTC')"
fi

CARGO_VERSION="${cargo_version}" perl -0pi -e 's/^version = "[^"]+"/version = "$ENV{CARGO_VERSION}"/m' Cargo.toml

if [[ -f Cargo.lock ]]; then
  CARGO_VERSION="${cargo_version}" perl -0pi -e 's/(\[\[package\]\]\nname = "camellia-remote"\nversion = ")[^"]+(")/$1$ENV{CARGO_VERSION}$2/' Cargo.lock
fi

APP_VERSION="${app_version}" perl -0pi -e 's/^version:.*/version: $ENV{APP_VERSION}/m' flutter/pubspec.yaml

mkdir -p src
cat > src/version.rs <<VERSION_RS
pub const VERSION: &str = "${cargo_version}";
#[allow(dead_code)]
pub const BUILD_DATE: &str = "${build_date}";
VERSION_RS

python3 .github/scripts/release_metadata.py >/dev/null
