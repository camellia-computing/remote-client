# Remote client UI

This package provides the Flutter interface for the desktop, mobile, and Web
remote client. The Rust core remains responsible for transport, capture, input,
clipboard, file transfer, and session security.

## UI architecture

- `lib/ui/camellia_design.dart` owns semantic color, type, radius, elevation,
  and motion tokens.
- `lib/common/widgets/adaptive_layout.dart` owns shared layout breakpoints,
  content bounds, reduced-motion behavior, and content states.
- `lib/common/widgets/brand_shell.dart` paints the runtime portal mark.
- `lib/ui/brand/portal_mark_spec.dart` is the single geometry source for both
  the runtime mark and generated platform assets.
- Desktop, mobile, and Web each expose one root workspace. Settings are an
  overlay or route, not a competing root destination.
- Remote-session command surfaces remain visible, labeled, keyboard reachable,
  and at least 44 logical pixels high.

The complete interaction and responsive contract is documented in
`../docs/ui-design-system.md`.

## Local verification

Format the Dart files changed by the branch from the repository root, then run
the package gates:

```bash
git diff --name-only --diff-filter=ACMR origin/main...HEAD -- 'flutter/**/*.dart' \
  | xargs -r dart format --output=none --set-exit-if-changed
cd flutter
flutter pub get --enforce-lockfile
flutter analyze --no-fatal-infos
flutter test
```

Build a target only after its native prerequisites are installed. Web-specific
commands and reproducible build inputs are documented in `web/README.md`.

## Brand assets

Do not edit exported PNG, ICO, ICNS, or platform launcher assets individually.
Change the shared mark specification or generator, then run:

```bash
dart run tool/generate_brand_assets.dart
cd ..
bash .github/scripts/verify-brand-assets.sh
```

The verifier regenerates every consumed artifact and fails when the reviewed
source and committed output differ.
