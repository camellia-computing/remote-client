# Localization maintenance

The production client maintains three catalogs:

- `en.rs` — English source/fallback catalog
- `cn.rs` — Simplified Chinese
- `tw.rs` — Traditional Chinese

`template.rs` is the key manifest used for parity checks; it is not a selectable
runtime language. Do not add another catalog without a product decision that
also updates locale resolution, Flutter supported locales, fonts, tests, and
this contract.

Add user-facing entries in the form:

```rust
("English key", "Translated value"),
```

Every maintained catalog and the template must contain the same unique keys.
Chinese values must be non-empty. English may intentionally fall back to the key
when the displayed wording is identical. Empty/default language selection
follows the operating system; Chinese script and region tags resolve to `zh-cn`
or `zh-tw`, while unsupported locales resolve to English.

The Flutter UI selects the bundled Noto Sans SC or Noto Sans TC family for the
matching Chinese catalog. Font files, their OFL-1.1 license, checksums, and
catalog parity are enforced by the Python maintenance tests. Run those tests and
the Flutter typography tests whenever catalog or font assets change.
