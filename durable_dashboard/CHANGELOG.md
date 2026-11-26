# Changelog

All notable changes to this package. Versions follow [Semantic
Versioning](https://semver.org); entries come from [Conventional
Commits](https://www.conventionalcommits.org).

## [2.1.1](https://github.com/wavezync/durable/compare/durable_dashboard-v2.1.0...durable_dashboard-v2.1.1) - 2026-11-26

### Bug fixes

- Key_scope: rollbacks keep the key, the line keeps its order ([d2c92ec](https://github.com/wavezync/durable/commit/d2c92ec8e3805d22fec431730c3e6aee707efdbb))
- Key_scope review findings: no line deadlock, rollback by stored scope ([10270b2](https://github.com/wavezync/durable/commit/10270b2be9cc702e5157748b8d68a44498f079d9))

## [2.1.0](https://github.com/wavezync/durable/compare/durable_dashboard-v2.0.1...durable_dashboard-v2.1.0) - 2026-11-24

### Features

- The graph draws lanes, and what a step's definition says ([58a024c](https://github.com/wavezync/durable/commit/58a024c925390facf14ab5872b1d3ffaa468a9c2))
- The run page says what a worker's lock means, and nodes show their clock ([2364dd8](https://github.com/wavezync/durable/commit/2364dd87c5662cbe3a58e14dbeca6981dc43e8e5))
- The site's logo in the sidebar, a favicon, and page titles ([64e4857](https://github.com/wavezync/durable/commit/64e4857f726d60a5ed9af0dc4d30de4db1766e83))
- The sidebar names the dashboard by a :label ([19faf71](https://github.com/wavezync/durable/commit/19faf71335640a5b1a70317fd300a813a66fa716))

### Bug fixes

- Times are shown by Durable's clock, the database's ([74866da](https://github.com/wavezync/durable/commit/74866daa4fc5575a5fa6d3a1620d6eec1da04817))

## [2.0.1](https://github.com/wavezync/durable/compare/durable_dashboard-v2.0.0...durable_dashboard-v2.0.1) - 2026-11-23

### Bug fixes

- A lane's page offers no Rerun, and points to its block's run ([4073cc1](https://github.com/wavezync/durable/commit/4073cc1c41a2e45602075a959366cff4a509f5f0))
- Show a rollback cut short by a lost worker in the operations feed ([f96443b](https://github.com/wavezync/durable/commit/f96443b14e61046ab47b2c0f121966a452221f67))

## [2.0.0](https://github.com/wavezync/durable/compare/durable_dashboard-v1.3.0...durable_dashboard-v2.0.0) - 2026-11-23

### Features

- Show failed claims and schedules removed from code ([9c91a1d](https://github.com/wavezync/durable/commit/9c91a1d1b14487b4690a706e96eb92c896232b30))
- Draw named branches and lanes in the graph ([d888b33](https://github.com/wavezync/durable/commit/d888b33b68731e3ebb4d0bf2b5fadbd1190c12d7))
- Optional lanes in a named parallel block ([f4939f4](https://github.com/wavezync/durable/commit/f4939f4264af3306d987b10dc01a35a30ef6c428))
- **Breaking:** A failed run is left as it failed; rollback is asked for ([0196dac](https://github.com/wavezync/durable/commit/0196dac964046275175353a8b84b64d2c0c2682f))
- Roll back a failed run from its page ([bd36478](https://github.com/wavezync/durable/commit/bd364788d474e6d109eb3bc79695df61dcb10eb9))
- Cancel and roll back; a failed run says when it rolls back by itself ([a877b96](https://github.com/wavezync/durable/commit/a877b9695db840220453d75efd67f3523f006e4a))
- Mount one dashboard per Durable instance with :as ([acf5f66](https://github.com/wavezync/durable/commit/acf5f6645d975e066a8ddbc8e3686375da772eb5))
- **Breaking:** Needs Durable 2.0 ([bace632](https://github.com/wavezync/durable/commit/bace6321d1e8cc418148ca22d511a99d20beb7e4))

### Bug fixes

- Handle every log level and hide run details from log labels ([fc48a90](https://github.com/wavezync/durable/commit/fc48a90c8edd1b99fd3244244d2a39f22bb54d57))
- Read step frames that carry their workflow ([ea73443](https://github.com/wavezync/durable/commit/ea734439da69ce16867f42a4f10f1c35f8cecd48))
- Named blocks in block statuses, the structure map and family views ([f3e6914](https://github.com/wavezync/durable/commit/f3e6914b0fa5ffad0da80805b35a3f850dac7514))
- Cancel crashed on a dashboard for a named Durable instance ([b06fc23](https://github.com/wavezync/durable/commit/b06fc234096ec747616aaafd4c46e0cd52a3e08b))
- An Inbox answer could land on a request the operator never saw ([1a7dda5](https://github.com/wavezync/durable/commit/1a7dda57e6ea49bd1338d25266d60f2d8754d8b6))
- An error whose message isn't text took down the Runs list and the run page ([7c5b4f1](https://github.com/wavezync/durable/commit/7c5b4f18db1df2ed502067c3571b3b5167d7f3b6))
- A form select with value/label options took the whole Inbox down ([e9ca69f](https://github.com/wavezync/durable/commit/e9ca69fd75e96fe3043f2a3c86bb719ad10d76d8))
- Approve pushed at a form request answered it without its checks ([a2a7f36](https://github.com/wavezync/durable/commit/a2a7f361fbb2f0430499106266dfc1a58224e968))
- Queues and Telemetry died on any message they didn't schedule ([c1ed3fb](https://github.com/wavezync/durable/commit/c1ed3fb26750158dcb22517076eff728dbfc2b8e))
- A missing asset was left unanswered instead of a 404 ([16a2659](https://github.com/wavezync/durable/commit/16a265976b1b2e9b8def3ff20e1d902ddd41d82b))
- Malformed query params gave 500s ([7828cc5](https://github.com/wavezync/durable/commit/7828cc55548cf1d4156db5c97b4d2a7e28ec7d4a))
- An event for something that isn't there crashed the page ([912de7d](https://github.com/wavezync/durable/commit/912de7d1aa656deb549e616e807581dbf462f430))
- A dashboard mounted at / loaded no styles or scripts ([bbf9d75](https://github.com/wavezync/durable/commit/bbf9d7579ff4018910ac9a924a0a6dff9689dbfd))
- A dashboard mounted inside a scope linked outside it ([5c425be](https://github.com/wavezync/durable/commit/5c425bef6f2391a5e3a22e0c7cde94e4b807df17))
- Runs that are each other's parent hung the run page ([480d083](https://github.com/wavezync/durable/commit/480d083d8139bdbfebd96b2934a09001a28bd50d))
- A run three levels down had no steps on its own page ([3aac512](https://github.com/wavezync/durable/commit/3aac512e124b4fd6e2705f0e8528fe5c6181f5cd))
- A cancelled run whose replaced_by isn't a run id crashed its page ([3ee1b43](https://github.com/wavezync/durable/commit/3ee1b43e7c142550798a94cd6ed2ab8828803674))
- The Overview crashed on a workflow event whose payload isn't a map ([9c49e82](https://github.com/wavezync/durable/commit/9c49e82d88ff7be62d1d36f9ce7213bc9d8d5271))

### Refactoring

- The pages call the engine's read functions in their new forms ([271dca3](https://github.com/wavezync/durable/commit/271dca3bb7fa8900ca767860c3b4ec2e969512a8))
- Engine state has its own column, out of the run's context ([3fce50f](https://github.com/wavezync/durable/commit/3fce50f52a0a03ba28dbf549b55e2165af3fdccb))

### Documentation

- Architecture notes for the new options; versioning decisions in the plan ([3b2bdb9](https://github.com/wavezync/durable/commit/3b2bdb904744885ec3be33e790130e9c4bb52fc2))
- Install 2.0, upgrade with the engine, :as in the guide, and what the Inbox does when a request changed ([31acc49](https://github.com/wavezync/durable/commit/31acc49648dd48c553a217a369d1f6a950653d5c))

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

