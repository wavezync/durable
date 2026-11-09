# Changelog

All notable changes to this package. Versions follow [Semantic
Versioning](https://semver.org); entries come from [Conventional
Commits](https://www.conventionalcommits.org).

## [1.3.0](https://github.com/wavezync/durable/compare/durable_dashboard-v1.2.2...durable_dashboard-v1.3.0) - 2026-11-09

### Features

- List the node drain events in the telemetry catalog ([d9ce5ce](https://github.com/wavezync/durable/commit/d9ce5cee91576106a82eae4150ab6fbc1151caa3))

## [1.2.2](https://github.com/wavezync/durable/compare/durable_dashboard-v1.2.1...durable_dashboard-v1.2.2) - 2026-11-09

### Documentation

- Add a guide to using the dashboard ([0c377fc](https://github.com/wavezync/durable/commit/0c377fcc39cf02bb629307a3563cc1c4b5c646e0))

## [1.2.1](https://github.com/wavezync/durable/compare/durable_dashboard-v1.2.0...durable_dashboard-v1.2.1) - 2026-11-09

### Bug fixes

- A cancelled step isn't shown as an error ([f548cfa](https://github.com/wavezync/durable/commit/f548cfa65df7d6acacd64697989aed679fdb90f5))

## [1.2.0](https://github.com/wavezync/durable/compare/durable_dashboard-v1.1.1...durable_dashboard-v1.2.0) - 2026-11-09

### Features

- List the step snooze event in the telemetry catalog ([13c14a0](https://github.com/wavezync/durable/commit/13c14a06dc7ad7de925089c9ec3dd8737f4973bc))
- Show why a pending run is waiting ([2318458](https://github.com/wavezync/durable/commit/231845884b4544a9356d1058324f658b71537100))

### Documentation

- Install snippets ask for durable 1.3 and durable_dashboard 1.2 ([17c07ac](https://github.com/wavezync/durable/commit/17c07ac81e7351ac88fd7b4f89840332ffc6b171))

## [1.1.1](https://github.com/wavezync/durable/compare/durable_dashboard-v1.1.0...durable_dashboard-v1.1.1) - 2026-11-06

### Bug fixes

- Readable type, calmer tooltips, run-first tables ([9c80f6b](https://github.com/wavezync/durable/commit/9c80f6b03da8ddc64fbd36cea6f0651a03d68817))

## [1.1.0](https://github.com/wavezync/durable/compare/durable_dashboard-v1.0.0...durable_dashboard-v1.1.0) - 2026-11-06

### Features

- Show and control workflow keys ([61f603b](https://github.com/wavezync/durable/commit/61f603be5d5d6d87e16e94a132728fce6f318b60))
- Add the Keys page and show replaced, sent and debounced runs ([97b88ca](https://github.com/wavezync/durable/commit/97b88ca3b0accc39c065076d1200a55170fd097f))

### Bug fixes

- Require durable 1.2, which has the workflow keys APIs ([c3b387a](https://github.com/wavezync/durable/commit/c3b387abe30ca4fb8fb7ceead349ceee9c5d2c88))

### Documentation

- Fix HexDocs source links; add a docs-only publish workflow ([4ee2d14](https://github.com/wavezync/durable/commit/4ee2d14927e57a26a4215776d174aacc581367be))
- Add badges and links to durable.wavezync.com in the READMEs ([b030c68](https://github.com/wavezync/durable/commit/b030c686ab4244e8df56664ac6b0ad233c9cc7ed))

## [1.0.0](https://github.com/wavezync/durable/compare/durable_dashboard-v0.1.0-rc...durable_dashboard-v1.0.0) - 2026-10-21

### Features

- V1 redesign — pages, design system, tooltips and query bar ([c05e87c](https://github.com/wavezync/durable/commit/c05e87c3ca40a800838800f7141b713e5d6e9292))
- Workflow graph with joins and branch gateways ([2a65c4d](https://github.com/wavezync/durable/commit/2a65c4dba4f772b0863b60cadb30919ffdb72bf7))

### Bug fixes

- Keep a run's first start time; dashboard fixes found by page tests ([7c4f55d](https://github.com/wavezync/durable/commit/7c4f55d963ad4316ab4c2e4f033174bcda13c5ca))

### Documentation

- Install snippets for 1.0 ([b13de21](https://github.com/wavezync/durable/commit/b13de217e22cbc4fc47330d6d18ef959f99a5a68))

## 0.1.0-rc - 2026-06-24

### Features

- Add durable_dashboard package ([d170094](https://github.com/wavezync/durable/commit/d170094e28b99f4b1b7ccf4dc66f5a83afef2668))
- Collapse to LiveView-first with a single React island ([cfac43d](https://github.com/wavezync/durable/commit/cfac43d6ff4c1cf9a0a5d3900143ab792a9fa948))
- Add setup/assets aliases and bundle assets on hex publish ([b0c8aa9](https://github.com/wavezync/durable/commit/b0c8aa99f9256bd75d617693050c2b90e5849af5))
- Redesign shell around the instrument-panel direction ([54f6a09](https://github.com/wavezync/durable/commit/54f6a0918bd74a0efc0e07fe0c135f7148a0f7d2))
- Shared UI primitives & display components ([c433ebb](https://github.com/wavezync/durable/commit/c433ebb32d83adcdcf74bc79b945f92a73307424))
- Workflow flow-graph island ([d6f2f9a](https://github.com/wavezync/durable/commit/d6f2f9a16b55a69559a50feb0ff63e23428bfd58))
- Workflow detail tabs ([7ea5c1c](https://github.com/wavezync/durable/commit/7ea5c1c2a58939aa1f277a24b50c6d5fe144318a))
- Overview, executions, workflows & settings pages ([58fba94](https://github.com/wavezync/durable/commit/58fba946e8e109e1ce74be6c899a8472c3a99025))
- Pulse brand mark, live ⌘K palette, topbar toolbar, wider inspector ([a1b2590](https://github.com/wavezync/durable/commit/a1b25909d18711fee16f97e7562dbde4980ef001))
- Copy buttons, full-width step inspector, faceted Executions filters ([9341826](https://github.com/wavezync/durable/commit/9341826f912b2344dae330d7c8c3288aa0402773))
- Workspace and dashboard precommit tooling ([daa10c9](https://github.com/wavezync/durable/commit/daa10c98679b7c04e3aefba36eb0796feaa7d1b0))

### Bug fixes

- Unbreak overview links and reorder Recent workflows ([3ae6c8f](https://github.com/wavezync/durable/commit/3ae6c8f759054c02423df482a57ffcaf88e7ca40))
- Resolve Elixir 1.20 gradual-type warnings and harden cold-build tests ([b1fbeb8](https://github.com/wavezync/durable/commit/b1fbeb8adff5d669ffc0eccdf3b2699b0187517d))

### Documentation

- Refresh READMEs for the dashboard IA + new features ([c2be144](https://github.com/wavezync/durable/commit/c2be14465f272ddf367f826aa0fee7bcb14f439e))

