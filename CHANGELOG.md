# Changelog

## [1.0.1] - 2026-08-01

### Fixes

- fix(windows): share MSI preprocessor metadata (#29) (`2b0106a3d086`)
- fix(release): authorize merged PR label cleanup (#30) (`d1d1c1417996`)

## [1.0.0] - 2026-07-31

### Features

- feat: establish Camellia Remote production baseline (`71090b9b378a`)
- feat(release): emit auditable candidate evidence (#17) (`d083ebfe622f`)
- feat(security): require authenticated encrypted Remote sessions (#19) (`d7ea2ed93b9a`)
- feat(release): automate verified client publication (#25) (`26a5e5ac1366`)

### Fixes

- security: consume redacted protocol revision (`e433c43040e2`)
- security: consume trust-revoking protocol revision (`0200af4c5cad`)
- security: enforce current storage and transfer bounds (`48a2c35449cb`)
- fix(release): accept full manual source CI (#16) (`fe20ab060fae`)
- fix(build): remediate unsafe legacy resource tooling (#22) (`8c4ae1a890b9`)
- fix(build): bind bridge normalization to generated sources (#23) (`4916f748d285`)
- fix(release): restore candidate lifecycle contracts (#26) (`c1aea2870ccc`)

### Other changes

- chore: pin validated protocol revision (`9d1a79ca2746`)
- ci: pin transitive Flutter setup dependencies (`c6894909891c`)
- ci: isolate vendored action inputs (`9705278823a4`)
- test: version visual regression baselines (`bb596e18481f`)
- ci: add explicit cross-platform release signing modes (#4) (`1eff2c94f44b`)
- ci: close cross-platform release validation gaps (#11) (`60ff2d8dbf74`)
- ci: finish cross-platform release candidate hardening (#12) (`44c64f5e3d3d`)
- ci: harden Apple release builds (#13) (`f36fc7e5571f`)
- docs(signing): consume organization configuration bundles (`7601363abf5d`)
- docs(signing): document existing Android update keys (`1e6068e56514`)
- ci: pin Apple toolchain and archive gate (#18) (`afb79d6c4e1e`)
- deps(actions): bump the workflow-actions group across 1 directory with 2 updates (#20) (`c4710b4325a1`)
- deps(web): bump typescript from 6.0.2 to 7.0.2 in /flutter/web/js in the web-dependencies group (#1) (`89001ef9c136`)
- deps(flutter): bump the flutter-dependencies group across 1 directory with 2 updates (#3) (`c5dee7769e9c`)
- refactor(ui): rebuild the remote client experience (#24) (`818f008cea9d`)
