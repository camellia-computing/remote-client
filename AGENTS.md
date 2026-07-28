# Camellia Remote engineering guide

## Project Layout

### Directory Structure
* `src/` Rust app
* `src/server/` audio / clipboard / input / video / network
* `src/platform/` platform-specific code
* `flutter/` current UI
* `libs/camellia_remote_protocol/` config / proto / shared utils
* `libs/scrap/` screen capture
* `libs/enigo/` input control
* `libs/clipboard/` clipboard
* `libs/camellia_remote_protocol/src/config.rs` all options

### Key Components
- **Remote Desktop Protocol**: Custom protocol implemented in `src/rendezvous_mediator.rs` for communicating with remote-server
- **Screen Capture**: Platform-specific screen capture in `libs/scrap/`
- **Input Handling**: Cross-platform input simulation in `libs/enigo/`
- **Audio/Video Services**: Real-time audio/video streaming in `src/server/`
- **File Transfer**: Secure file transfer implementation in `libs/camellia_remote_protocol/`

### UI Architecture
- **UI**: Flutter-based - files in `flutter/`
  - Desktop: `flutter/lib/desktop/`
  - Mobile: `flutter/lib/mobile/`
  - Shared: `flutter/lib/common/` and `flutter/lib/models/`

## Video Quality Model

The encoder target is

    base_bitrate(width, height) * Quality::ratio() * fps_bitrate_scale(fps)

all defined in `libs/scrap/src/common/codec.rs`. `VideoQoS::ratio()`
(`src/server/video_qos.rs`) applies the frame-rate term, so the adaptive control
loop keeps reasoning in quality space alone.

Two invariants to preserve when touching any of it:

* **Bits are spent per frame.** A target that ignores frame rate divides the
  same bandwidth across more frames, so quality silently collapses exactly where
  the display is fastest. Any new rate path must keep the fps term.
* **The quantizer must be allowed to spend what the rate controller grants.**
  `calc_q_values` in `vpxcodec.rs` / `aom.rs` widens the quantizer window across
  the whole reachable ratio range; capping it hands out bandwidth the encoder is
  then forbidden to use.

Changes here are measurable rather than a matter of taste. The harness in
`libs/scrap/src/common/quality_harness.rs` encodes synthetic desktop content and
reports encode/decode time, achieved bitrate, PSNR and SSIM:

    cargo test -p scrap --features linux-pkg-config --release -- \
        --ignored --nocapture bitrate_model_matrix

Note `scrap` needs `--features linux-pkg-config` on a machine without
`VCPKG_ROOT`.

## Rust Rules

* Avoid `unwrap()` / `expect()` in production code.
* Exceptions:

  * tests;
  * lock acquisition where failure means poisoning, not normal control flow.
* Otherwise prefer `Result` + `?` or explicit handling.
* Do not ignore errors silently.
* Avoid unnecessary `.clone()`.
* Prefer borrowing when practical.
* Do not add dependencies unless needed.
* Keep code simple and idiomatic.

## Tokio Rules

* Assume a Tokio runtime already exists.
* Never create nested runtimes.
* Never call `Runtime::block_on()` inside Tokio / async code.
* Do not hide runtime creation inside helpers or libraries.
* Do not hold locks across `.await`.
* Prefer `.await`, `tokio::spawn`, channels.
* Use `spawn_blocking` or dedicated threads for blocking work.
* Do not use `std::thread::sleep()` in async code.

## Editing Hygiene

* Change only what is required.
* Prefer the smallest valid diff.
* Do not refactor unrelated code.
* Do not make formatting-only changes.
* Keep naming/style consistent with nearby code.

## Localization (`src/lang/*.rs`)

Each file is a `HashMap<key, translation>`. Layout:

* `template.rs` is the master list of every key. **Never edit it** as part of translation work.
* `en.rs` holds only the keys whose English display text differs from the key itself.
* Every other file (`de.rs`, `fr.rs`, …) carries the full key set; an untranslated entry has an empty value: `("key", "")`.

### Finding the English source for a key

When filling an empty entry, determine the source English text with this rule:

* If `key` exists in `en.rs` **with a non-empty value**, that value is the source text (look it up in `en.rs`).
* Otherwise the **key string itself is the source text** (the key is already plain English).

Then translate that source into the file's target language (infer the language from the file's existing non-empty entries / filename).

### Translation hygiene

* Only fill empty values. Never change keys, and never touch existing non-empty translations.
* Preserve placeholders (`{}`) and escape sequences (`\n`, `\"`) exactly as in the source.
* Do not translate brand or technical tokens: `Camellia Remote`, `Socks5`, `TLS`, `UAC`, `Wayland`, `X11`, `TCP`, `UDP`, `2FA`, `RDP`, `D3D`, etc.
* Copy URL values (e.g. `doc_*` keys) verbatim from `en.rs`.
