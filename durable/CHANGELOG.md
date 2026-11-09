# Changelog

All notable changes to this package. Versions follow [Semantic
Versioning](https://semver.org); entries come from [Conventional
Commits](https://www.conventionalcommits.org).

## [1.4.0](https://github.com/wavezync/durable/compare/durable-v1.3.0...durable-v1.4.0) - 2026-11-09

### Features

- A stopping node lets running work finish ([5296b76](https://github.com/wavezync/durable/commit/5296b7699dae7007146da58b2d779dbd823096cb))

### Performance

- Claim from a deep backlog without sorting it ([d681398](https://github.com/wavezync/durable/commit/d681398712b6ee11fd4cf7ce58f0fba0f9595b52))

### Documentation

- Install snippets ask for durable 1.3 and durable_dashboard 1.2 ([17c07ac](https://github.com/wavezync/durable/commit/17c07ac81e7351ac88fd7b4f89840332ffc6b171))
- Say when to fail and when to cancel in the Oban guide ([cde9940](https://github.com/wavezync/durable/commit/cde99408c7ff11b33bfbe3cd8f7c5ab0fb568331))
- Add a running in production guide ([9114190](https://github.com/wavezync/durable/commit/911419077b74b869f0a49cdf6afc7165eac233f5))
- The production guide no longer needs its workarounds ([d316f81](https://github.com/wavezync/durable/commit/d316f81b7ac9948fb8458df4e06299b4eec8d750))

## [1.3.0](https://github.com/wavezync/durable/compare/durable-v1.2.0...durable-v1.3.0) - 2026-11-09

### Features

- Stop a run from a step, and read the attempt number ([ccdd3ae](https://github.com/wavezync/durable/commit/ccdd3aef2924d01c67cc858c6ddf92048323b73a))
- Choose what a step's {:cancel, reason} cancels ([44cf980](https://github.com/wavezync/durable/commit/44cf9802a5fd8475cc1f1166e8bca29a620bc1ec))
- Assert_started, refute_started and all_started test helpers ([c839d8b](https://github.com/wavezync/durable/commit/c839d8bd6d0652e999d4673763f26d27b0fda7eb))
- Park the run between retries, and let a step snooze ([bb7deee](https://github.com/wavezync/durable/commit/bb7deee19335adf1e83c65038e71b38714d0a380))
- Cron schedules can start their runs with a key ([0523230](https://github.com/wavezync/durable/commit/0523230e3a6c4e9ca4ae662c9d8533d25848e03a))
- Tag runs, find them by tag, and cancel_all ([53c4a0b](https://github.com/wavezync/durable/commit/53c4a0bcc1485dc6645808e510559bb90717bedf))
- Start_many starts several runs in one transaction ([dfab38b](https://github.com/wavezync/durable/commit/dfab38bee79eed4894e121913394d1a375de4624))
- On_duplicate: :run_again runs once more after the holder ([ca389fd](https://github.com/wavezync/durable/commit/ca389fd2d9368ff97c99cc69ac0728dfb8cc78f6))
- Wake a queue's pollers when a run starts or resumes ([69e9a37](https://github.com/wavezync/durable/commit/69e9a37cfbaef397f25ac94500fa511d898a3924))
- A step's queue: moves the run there for that step ([0f71b40](https://github.com/wavezync/durable/commit/0f71b40a452ff61e3d6c0fa109052de7d00678c1))
- Tell subscribers when a run parks, and expose where it waits ([adb1b0a](https://github.com/wavezync/durable/commit/adb1b0a19ccd0f57c9ed768f15cf97274b637449))

### Bug fixes

- List_executions(workflow: Module) matched no runs ([55a97b7](https://github.com/wavezync/durable/commit/55a97b71e4cf47885ac1f659ba033ac9bbada0be))
- A run resumed inside a branch stays on its own clause ([16f7886](https://github.com/wavezync/durable/commit/16f78868ec30e976d166f24d89d5c8c6eb438747))
- Boot with more than one queue ([65d4069](https://github.com/wavezync/durable/commit/65d4069ba9b41b08dcd8c38e0b3eaf392be74959))
- A rerun starts on the queue the run started on ([e057f1b](https://github.com/wavezync/durable/commit/e057f1b990986ff12ebf471d2ab0e4d2707f99ed))
- Time out runs on a queue no live node polls ([6dc1fa2](https://github.com/wavezync/durable/commit/6dc1fa2d9f0588691de968bcb8219d78922625e5))
- A parent no longer hangs on a child that ends early or compensates ([4ddb6af](https://github.com/wavezync/durable/commit/4ddb6af16948382dd674211327e4f12b153189cc))
- Start_many wakes pollers after its commit ([6e48d26](https://github.com/wavezync/durable/commit/6e48d26ff68dec270517f1c60d4ff87d43456e92))
- A compensation returning an error counts as failed ([5bebad4](https://github.com/wavezync/durable/commit/5bebad41aa60cbea7a8365c68e029ce05e82593c))
- A wait commits together with the run's :waiting status ([115272e](https://github.com/wavezync/durable/commit/115272ebe4dd211fed032c5d29308ed76c467118))
- A wake sent inside a transaction arrives at its commit ([30762e5](https://github.com/wavezync/durable/commit/30762e5ca97f6919bccb23b038db691d08c5cd04))
- The timeout sweep no longer runs compensations itself ([9c5bc5d](https://github.com/wavezync/durable/commit/9c5bc5d263b04e0c17e6965f24f38039e7640edc))
- No value a workflow hands over can poison a row ([3b52fa5](https://github.com/wavezync/durable/commit/3b52fa5a12d3bd4bcdf60931a8882c28c73a03cd))
- Bad ids and text get an answer, not a database error ([d662012](https://github.com/wavezync/durable/commit/d6620129cc5ae38cb3cea5cc1269a6eca5b62df6))
- Deadlock, leftover wait_for_any events and a slot race ([0119e69](https://github.com/wavezync/durable/commit/0119e69674352160d7703f5facebda43fbc1b49b))
- A parallel branch that waits no longer repeats the workflow ([881a585](https://github.com/wavezync/durable/commit/881a58582a6c87e0be1554ca9f9675df4b3d3ec2))
- Resuming a run no longer creates atoms, and nil is an answer ([3e0c1e9](https://github.com/wavezync/durable/commit/3e0c1e98de3bfe1f1ce1b5800377dd1a4dbe2739))
- A child's input is checked, and a poller survives a bad row ([a388ec1](https://github.com/wavezync/durable/commit/a388ec19bca90f9efdadb35ddbdef659d32582d9))
- Wake on commit without LISTEN, so PgBouncer works ([cb76895](https://github.com/wavezync/durable/commit/cb768957c9d3999940be949d6df7e3bec1ce8d8f))
- A list or nil option can't reach the database as a raw error ([4b6ba7a](https://github.com/wavezync/durable/commit/4b6ba7a52f5bee30de77b9f049c71e1cdd0da994))

### Documentation

- Coming from Oban, production settings, and stale parallel notes ([651002a](https://github.com/wavezync/durable/commit/651002a61dd23d3832ad1748e239bce79d382eec))
- State the PostgreSQL version Durable needs ([5d005a4](https://github.com/wavezync/durable/commit/5d005a4d8080909085501cfaec41c34e89815c71))
- Bring the guides, README and website up to date ([ace3967](https://github.com/wavezync/durable/commit/ace3967a18fe8fef4432fdb5a6bca98552fb657f))
- Replace agents/ and docs/bug-reports with ARCHITECTURE.md and PLAN.md [skip ci] ([36aaee6](https://github.com/wavezync/durable/commit/36aaee69e3c3e152c9bc1148770326bdd93bc88b))

## [1.2.0](https://github.com/wavezync/durable/compare/durable-v1.1.0...durable-v1.2.0) - 2026-11-06

### Features

- Stop a step at its timeout or the run's deadline ([5a2d483](https://github.com/wavezync/durable/commit/5a2d483bc30c027478155ba44740205077a28068))
- Add workflow keys, so a key starts at most one run ([bd05157](https://github.com/wavezync/durable/commit/bd051570fd37c15128dbb1a34f916c53d7ed5201))
- Replace, signal or debounce a run whose key is taken ([e6b7431](https://github.com/wavezync/durable/commit/e6b7431893c7ff3baff7cb7a3bcb9a24b55f7937))

### Bug fixes

- Evaluate step option values, so seconds(1) is a number ([52af677](https://github.com/wavezync/durable/commit/52af677497586a12d3ac0d34868a22b95800d8e3))
- Fail the run when an input wait times out with on_timeout: :fail ([0f8c177](https://github.com/wavezync/durable/commit/0f8c177a43046d61fc5fe0496645ba5a0845e9f2))
- Fail a run whose current step a deploy removed ([67fc7d1](https://github.com/wavezync/durable/commit/67fc7d1229ff6f367b87f7ad657ca7c957ffabb8))
- Keep a Stats window's last moments in its last bucket ([6799542](https://github.com/wavezync/durable/commit/67995421eeb366aa649ff5681887ee14dc5d17cd))

### Documentation

- Add the workflow keys guide and plan M09 ([13d4cce](https://github.com/wavezync/durable/commit/13d4cce75bc57513aff7c4eb721499d16928aff3))
- Cover cancel_existing, send_event, debounce and the Keys page ([1feb9a8](https://github.com/wavezync/durable/commit/1feb9a87c830abe742e2504da33b4b8d5de74583))

## [1.1.0](https://github.com/wavezync/durable/compare/durable-v1.0.0...durable-v1.1.0) - 2026-10-23

### Features

- Add Durable.Testing helpers for testing workflows ([609c7e4](https://github.com/wavezync/durable/commit/609c7e4d11d2d09cd9d1f2d466354be94fae97a8))

### Bug fixes

- Store string step errors as maps instead of leaving the run running ([bfd5c85](https://github.com/wavezync/durable/commit/bfd5c8572b867de5fa32fab76e192f1dd2c2d134))

### Documentation

- Fix HexDocs source links; add a docs-only publish workflow ([4ee2d14](https://github.com/wavezync/durable/commit/4ee2d14927e57a26a4215776d174aacc581367be))
- Add badges and links to durable.wavezync.com in the READMEs ([b030c68](https://github.com/wavezync/durable/commit/b030c686ab4244e8df56664ac6b0ad233c9cc7ed))

## [1.0.0](https://github.com/wavezync/durable/compare/durable-v0.1.0-rc...durable-v1.0.0) - 2026-10-21

### Features

- Schema for operator controls, deadlines and history ([fd69e82](https://github.com/wavezync/durable/commit/fd69e82f93ae9e5c38965300f25cd0c6281512d0))
- Telemetry events and metrics ([d3e7983](https://github.com/wavezync/durable/commit/d3e7983586ec8271ea037eb40c82ce6372157966))
- Operator controls, workflow timeouts and run observability ([0164365](https://github.com/wavezync/durable/commit/0164365438d320aaf2a3e5abfcd7be25f4d7d176))

### Bug fixes

- Stable ids for parallel and branch blocks ([333c152](https://github.com/wavezync/durable/commit/333c152301aa68608eee76e6403900fc64687c38))
- Keep a run's first start time; dashboard fixes found by page tests ([7c4f55d](https://github.com/wavezync/durable/commit/7c4f55d963ad4316ab4c2e4f033174bcda13c5ca))

### Documentation

- Workflow options, errors, telemetry and the operator API ([0cd4256](https://github.com/wavezync/durable/commit/0cd42560f0cee57acb6e5783d608abfe57251ca8))
- Install snippets for 1.0 ([b13de21](https://github.com/wavezync/durable/commit/b13de217e22cbc4fc47330d6d18ef959f99a5a68))

## 0.1.0-rc - 2026-06-24

### Features

- Collapse to LiveView-first with a single React island ([cfac43d](https://github.com/wavezync/durable/commit/cfac43d6ff4c1cf9a0a5d3900143ab792a9fa948))
- Harden durable execution — sleep/wait, fencing, retries, child workflows ([6b56c35](https://github.com/wavezync/durable/commit/6b56c351073bc40c88d964e2ce01eb029e47d9c1))
- Copy buttons, full-width step inspector, faceted Executions filters ([9341826](https://github.com/wavezync/durable/commit/9341826f912b2344dae330d7c8c3288aa0402773))

### Bug fixes

- Resolve Elixir 1.20 gradual-type warnings and harden cold-build tests ([b1fbeb8](https://github.com/wavezync/durable/commit/b1fbeb8adff5d669ffc0eccdf3b2699b0187517d))

### Documentation

- Refresh READMEs for the dashboard IA + new features ([c2be144](https://github.com/wavezync/durable/commit/c2be14465f272ddf367f826aa0fee7bcb14f439e))

