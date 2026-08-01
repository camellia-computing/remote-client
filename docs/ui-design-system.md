# Client UI design system

This document defines the production UI contract shared by desktop, mobile,
and Web clients. Product names, server addresses, account identities, and
organization metadata are runtime inputs; layout code must not depend on a
specific deployment name.

## Information architecture

The client has one root workspace containing connection, incoming-access, and
device-management capabilities supported by the current build. Expanded
layouts use a 296–336 px functional incoming-access pane, not a navigation
sidebar: it contains the local ID, one-time password, access health, and the
single Settings entry. Devices exist only in the main workspace. There is no
root account control or bottom navigation. Settings open as a titled modal
surface on larger windows and as a full-screen route on compact devices.
Account actions, when enabled, live in their relevant settings or device
context.

Remote sessions use a separate command surface because the remote canvas is the
primary task. Desktop and Web command bars can dock to any edge and persist one
versioned placement record. Mobile command actions remain in a fixed safe-area
dock; secondary actions use structured sheets or dialogs.

## Responsive contract

Layout decisions use available logical width, not device names or platform
checks:

| Width | Class | Workspace behavior |
| --- | --- | --- |
| `< 600` | compact | 16 px page inset; capability cards stack; full-screen settings |
| `600–1023` | medium | 24 px inset; bounded content; settings side panel when space permits |
| `≥ 1024` | expanded | 296–336 px access pane; bounded Connect card over an expanding Devices region; centered settings dialog |

Primary content is capped rather than stretched across ultrawide displays.
Every compact layout must scroll vertically without clipped actions. Text scale,
safe-area insets, keyboard insets, and right-to-left direction are allowed to
change geometry; fixed text-scale wrappers are prohibited.

Devices uses component-local breakpoints so it remains fluid inside either the
root workspace or a future embedded surface. Below 520 px, categories use one
compact selector; otherwise they wrap without horizontal scrolling. Device
actions stack below 440 px, use two rows from 440–639 px, and share one row from
640 px. Search fills a narrow row but is capped to 220–320 px on wider layouts.

## Visual language

`camellia_design.dart` is the semantic token source. The product has one visual
language with deliberately distinct light and dark palettes, not multiple
component skins. Components consume color-scheme roles and `AppVisual` tones
rather than literal colors. Azure identifies connection and information, aqua
success and healthy transport, coral attention and destructive session exit,
and indigo the secure portal identity. Color is never the only status indicator.

Surfaces use a restrained hierarchy: page backdrop, section surface, inset
control, and transient elevated surface. Border radius, elevation, spacing, and
motion come from shared tokens. Controls have a minimum visual height of 44
logical pixels and a minimum touch target of 48 where the platform permits.

Motion communicates state change only. Hover, feedback, content, modal, and
route durations use `AppMotion`; `MediaQuery.disableAnimations` reduces them to
zero. Repeating ornamental animation is not part of the root workspace.

## Component behavior

- Desktop chrome provides a 40 px platform-aware title bar. Windows and Linux
  expose drag, system menu, minimize, maximize/restore, and close behavior;
  macOS retains the native traffic-light controls.
- Connect readiness is part of the Connect section header, never a detached
  footer. The access pane owns the only root Settings action.
- Device categories are mutually exclusive and never control the visibility of
  search or peer actions. Category selection, search, refresh, and view controls
  remain independent. View and sort use the same borderless 44 px trigger and
  selectable-row pattern; their menus are 184–216 px wide, omit duplicate
  headings, and use one hover/action layer per row.
- Credential dialogs group each credential type, keep labels adjacent to their
  controls, present validation inline, prevent duplicate submission, and use
  aligned Cancel/Connect actions.
- Session status uses a compact two-column information panel and always exposes
  secure state, direct/relay route, protocol, latency, throughput, frame rate,
  bitrate, codec, and chroma as text. Unknown values render as an em dash.
- The remote canvas is never covered by persistent action labels. Desktop/Web
  command buttons use a 40 px icon target with tooltip, semantic label, focus,
  and hover state. Status, control, display, and close remain directly available;
  secondary actions progressively move into a labeled More menu at 720, 560,
  and 420 px dock extents. Menus are viewport-bounded and scroll when necessary.
  The collapsed command bar retains an icon-only restore action with an explicit
  tooltip and semantic label. Mobile touch targets remain at least 48 px.
- Settings surfaces always have a root Settings header plus the selected
  section header. Desktop navigation is 216 px wide, content is capped at
  720 px, and rows use compact desktop density without dropping accessible
  interaction targets. New screens use the in-tree Material 3 components.

## Accessibility and localization

Interactive icons require tooltips and semantic labels. Selection, toggle,
busy, secure, and destructive state must be exposed to assistive technology.
Keyboard traversal follows visual order, Escape cancels dismissible dialogs,
and Enter submits only when validation permits. Focus must not be trapped or
discarded when responsive layouts change.

All user-facing text goes through the localization bridge. The maintained
catalogs are English, Simplified Chinese, and Traditional Chinese. Empty/default
selection follows the operating-system locale; Chinese script/region variants
resolve to the corresponding Chinese catalog and every other unsupported locale
falls back to English. Noto Sans SC/TC variable fonts are bundled under OFL-1.1
and selected for the matching Chinese catalog so mixed Latin/CJK text keeps one
global typographic rhythm. Layouts must tolerate long translations and 200% text
scaling without hiding the only path to an action. Examples and fixtures use
synthetic identifiers and must not contain real people, hosts, organizations,
tokens, or service endpoints.

## Brand asset contract

The portal mark represents two offset screens joined by a secure transport
node. The connector follows the exact 45-degree screen-offset axis and is
centered on the canvas. `portal_mark_spec.dart` is the geometry source for the
runtime painter and `tool/generate_brand_assets.dart`. Generated PNG, ICO, ICNS,
SVG, Android, Apple, Windows, Web, and tray assets are reviewed outputs and must
never be edited independently. CI regenerates them and rejects drift.

## Review gates

UI changes require formatting, static analysis, unit/widget tests, catalog/font
integrity checks, and reviewed light/dark responsive goldens. Tests cover exact
breakpoints, reduced motion, settings interaction, command-bar tiers and
persistence, invalid persisted data, typography selection, and brand geometry.
Platform builds remain the authority for native packaging, font rendering,
accessibility services, title-bar behavior, and launcher-mask behavior.
