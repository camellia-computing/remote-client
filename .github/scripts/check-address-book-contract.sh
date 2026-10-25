#!/usr/bin/env bash
set -euo pipefail

client_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
probe_dir="$(mktemp -d)"
cleanup() {
  # Only compiler-generated files in this newly allocated directory; refuse to
  # recurse if an unexpected directory appears. No project/cache tree deletion.
  find "$probe_dir" -maxdepth 1 -type f -delete
  rmdir -- "$probe_dir"
}
trap cleanup EXIT
cd "$client_root/flutter"
dart compile js -O2 test/support/address_book_mutations_js_probe.dart -o "$probe_dir/mutations.js"
node "$client_root/.github/scripts/test-address-book-mutations-js.cjs" "$probe_dir/mutations.js"
dart compile js -O2 test/support/address_book_journal_web_probe.dart -o "$probe_dir/journal.js"
node "$client_root/.github/scripts/test-address-book-journal-web.cjs" "$probe_dir/journal.js"
dart compile js -O2 test/support/http_browser_probe.dart -o "$probe_dir/http.js"
node "$client_root/.github/scripts/test-http-browser.cjs" "$probe_dir/http.js"
