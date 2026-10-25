#!/usr/bin/env bash
set -euo pipefail

client_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
node "$client_root/.github/scripts/test-address-book-mutations-js.cjs"
node "$client_root/.github/scripts/test-address-book-journal-web.cjs"
node "$client_root/.github/scripts/test-http-browser.cjs"
