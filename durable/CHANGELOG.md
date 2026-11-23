# Changelog

All notable changes to this package. Versions follow [Semantic
Versioning](https://semver.org); entries come from [Conventional
Commits](https://www.conventionalcommits.org).

## [2.0.2](https://github.com/wavezync/durable/compare/durable-v2.0.1...durable-v2.0.2) - 2026-11-23

### Bug fixes

- What a failed step leaves, and data a save can't take ([9c28811](https://github.com/wavezync/durable/commit/9c288118a7788e58cfbf2fe618573c525af3b249))
- Cancels with rollback, partial rollbacks, run_again without a holder, compensation timeouts ([29fe16b](https://github.com/wavezync/durable/commit/29fe16b37ad49fd28940208f9c5df32137ed7846))
- Workers that lost their claim stop, and runs go back to their own node ([35dc5ab](https://github.com/wavezync/durable/commit/35dc5abc9c4bdd389eceecbf388ef5c4fab5ea08))
- Blocks and child workflows that stalled, ran twice or answered wrong ([1cbe344](https://github.com/wavezync/durable/commit/1cbe3445f0e276c4687ccba827fae51ad5dac690))
- A snooze no timestamp holds is an invalid return, not a crash in the save ([b16e2a5](https://github.com/wavezync/durable/commit/b16e2a5cfd52e9ba403dcc95366da2f1c368e500))
- Each wait gets its own answer; waits and schedules survive crashes and clock changes ([28eced1](https://github.com/wavezync/durable/commit/28eced141accfb6e81e05f7c04cd814ce6290c28))
- An answer that is a date or a decimal is stored wrapped, and read back ([f23bb89](https://github.com/wavezync/durable/commit/f23bb894f33cc59f1bf0eb67574b99819894b480))
- A rollback keeps its error, a cancelled run never holds a key, and the sweeps are bounded ([300c29b](https://github.com/wavezync/durable/commit/300c29b5c9528adddde10721b06e3c0f66800e39))
- Lane timeouts on unpolled queues, stale lane notices, lost close-outs of cancelled lanes ([d52fbc1](https://github.com/wavezync/durable/commit/d52fbc183b03ab3f03329dfc07fb28cbfc0ac534))
- A key a step deleted stays deleted when its worker is lost, and a deadline never stops a step early ([b6f4485](https://github.com/wavezync/durable/commit/b6f4485369df86e8f1d68a0b81640e1c492a5362))
- A clean stop at grace 0 hands runs back, inline runs take a claim, one poll timer ([a97a462](https://github.com/wavezync/durable/commit/a97a46217e6033defb51f1fefe7de34583e5c301))
- A worker settles its own run, and the ack is fenced ([d55a956](https://github.com/wavezync/durable/commit/d55a9569ea777b0876237417d8583ada95280030))
- Every timeout sweep reads oldest first and pages past what it can't handle ([f24a73c](https://github.com/wavezync/durable/commit/f24a73ca3062055c099fda2426f6bc56537f720f))
- An edit to a schedule is made to it as it is, under its row's lock ([fdf96ae](https://github.com/wavezync/durable/commit/fdf96ae6b3d79cc00e22a44738f2615749f0d7e5))

### Refactoring

- One is_run_data guard, and drop a ponytail the child record made stale ([29d840a](https://github.com/wavezync/durable/commit/29d840a9653e3be88aa6bb130409211f814ac48d))

## [2.0.1](https://github.com/wavezync/durable/compare/durable-v2.0.0...durable-v2.0.1) - 2026-11-23

### Bug fixes

- A workflow's data has string keys in every step, at every depth ([123d914](https://github.com/wavezync/durable/commit/123d9141c0a97380973757688c15c22689811a2a))
- Helpers are the documented way to read data, and read inside it ([b1b8fae](https://github.com/wavezync/durable/commit/b1b8faeb08039d121c4ea29e703f633d8eabccab))

## [2.0.0](https://github.com/wavezync/durable/compare/durable-v1.5.0...durable-v2.0.0) - 2026-11-23

### Features

- Trace attempts with OpenTelemetry and close the review's bugs ([2da3a34](https://github.com/wavezync/durable/commit/2da3a34f2afcee710b7a7f2f258bbc06329f19bd))
- Named branches and lanes, run by the executor ([63a3470](https://github.com/wavezync/durable/commit/63a34705e6d170d750970b671cf899163a0edb7d))
- Optional lanes in a named parallel block ([f4939f4](https://github.com/wavezync/durable/commit/f4939f4264af3306d987b10dc01a35a30ef6c428))
- A lane hands the next step what it produced, not its whole data ([34e7277](https://github.com/wavezync/durable/commit/34e72770ddab07e9d94fa70a6fbc461df9af46b2))
- **Breaking:** A failed run is left as it failed; rollback is asked for ([0196dac](https://github.com/wavezync/durable/commit/0196dac964046275175353a8b84b64d2c0c2682f))
- Rollback_plan/2 names what a rollback would run ([72353c7](https://github.com/wavezync/durable/commit/72353c76470dc478f4f1609988b3c428339ae952))
- **Breaking:** A parallel block takes a name ([2446be6](https://github.com/wavezync/durable/commit/2446be619f5b5bf04720cfea297f4d0f0db39448))
- Cancel(id, reason, rollback: true) undoes the run it cancels ([da8f5b0](https://github.com/wavezync/durable/commit/da8f5b0270e8cf576f0e1cff02858c6303fbacab))
- Default: and timeout: on a lane ([31f68f6](https://github.com/wavezync/durable/commit/31f68f6c490ff1d9ed1627e023b2a681d870490b))
- On_failure: [rollback_after: ms] undoes a failed run nobody acted on ([0f1618f](https://github.com/wavezync/durable/commit/0f1618f77257f51027ecf0952b2b00699bc6b68c))
- An event kept with buffer: true reaches wait_for_any and wait_for_all ([028672b](https://github.com/wavezync/durable/commit/028672b643ddf68b2ef49047efb183eade40ee40))
- Cancel_wait on a run waiting for its lanes or its child cancels their waits ([d734e00](https://github.com/wavezync/durable/commit/d734e0015ce829bc1cbf96bc2dd193b741abf4f0))
- A workflow definition that can't work is refused, or warned about, when it compiles ([181ee76](https://github.com/wavezync/durable/commit/181ee768a8cda6998f5313d6199300cd63b1a9a6))
- Queue settings that can't work are refused when Durable starts ([6fab6f3](https://github.com/wavezync/durable/commit/6fab6f336593f3fe2004252831e4b2f32b0167e2))
- **Breaking:** Every function that reads returns {:ok, result} or {:error, reason}, with a ! twin ([5b344d6](https://github.com/wavezync/durable/commit/5b344d61bf415e0f3efe11087a679d9897a3c547))
- A read function refuses an option it doesn't know ([97a3f8d](https://github.com/wavezync/durable/commit/97a3f8d67505d45251a97a98e18089947a3afb87))
- Durable.cancel_wait/2, beside the other things an operator does ([e5548b0](https://github.com/wavezync/durable/commit/e5548b0644e7d26f983a239da88e863383ad8971))

### Bug fixes

- Make dead steps fail, stop retries starving, close the 1.5.0 gaps ([ff2d428](https://github.com/wavezync/durable/commit/ff2d42849875324a346ffdf001669ec2494c4270))
- Stop a stale lock failing healthy runs and fix flaky CI ([7c663cd](https://github.com/wavezync/durable/commit/7c663cdb9fce84d0392b3904a1e6808c079e1005))
- Treat a connection lost through PgBouncer as lost ([be3c319](https://github.com/wavezync/durable/commit/be3c31961f3560dc67f53717622c569ab0173613))
- Close issue #36 and what the engine audit found ([f989d13](https://github.com/wavezync/durable/commit/f989d13717222c5b20b6b5c07c8e4842b8e5e454))
- Retry guards for keyed runs, step names in compile-time arms ([2744430](https://github.com/wavezync/durable/commit/274443077c9639c42a6736f8bc47eb961fddb5a8))
- Named blocks beside retries, queues and unnamed blocks; on_error: :collect ([2fe7b9b](https://github.com/wavezync/durable/commit/2fe7b9b81c2e90dffa1d929f6aa76c626e4a3373))
- A run lost outside a step carries on; it isn't compensated ([14613d1](https://github.com/wavezync/durable/commit/14613d1b64d27e601418e4c2efbc474664cda9b9))
- A cancel's rollback waits for the worker that had the run ([e9ea02e](https://github.com/wavezync/durable/commit/e9ea02e9504b52569ad388338272fb475fb48963))
- A step's start event comes before its row can be closed ([0afa6b1](https://github.com/wavezync/durable/commit/0afa6b13becac33b779d4cc57b9ed5fea3bc2d8a))
- A run failed by a dead worker was rolled back a minute later ([a03ac29](https://github.com/wavezync/durable/commit/a03ac292703976a3472ea1272ede85375b39476b))
- Cancelling a run that never started, with rollback: true, kept its key from the next start ([647c61f](https://github.com/wavezync/durable/commit/647c61fb25a2e92cf10088a5b52f597c80bc3d93))
- A worker lost as a rollback began left the run to carry on with its steps ([8797f14](https://github.com/wavezync/durable/commit/8797f14a1fa6231120a2a304a6003e9bfe4b4ce9))
- A failed run waiting to be rolled back could be pruned first ([7bf6f6c](https://github.com/wavezync/durable/commit/7bf6f6cbed7ed54afc5d47759ba7cce78dc678d6))
- An into: that returned anything unexpected crashed the worker ([8678206](https://github.com/wavezync/durable/commit/8678206c354343717bbf26aefe1431fae0b519a9))
- A rollback claimed by a node without the workflow's code was thrown away ([7ebb718](https://github.com/wavezync/durable/commit/7ebb7180601ea730a23d7768e23aca98103cdab1))
- A rollback lets its key go, waits for stopped lanes, and a retry brings back a lane's child workflow ([546fea0](https://github.com/wavezync/durable/commit/546fea0ffcb79c1a084883638fba673a3d7db2ec))
- A child workflow's timeout was never applied ([685450a](https://github.com/wavezync/durable/commit/685450a7b0408425e0b04b03e0fa0b46266d9848))
- A retried lane inside a lane could outlast the lane it is in ([cb1969b](https://github.com/wavezync/durable/commit/cb1969bc89c3f9b0589c5fe1fd5503c5bbd3f9da))
- A run that timed out waiting for its child workflow could never be retried ([987eb62](https://github.com/wavezync/durable/commit/987eb62d5841dbb3f6f91bd4be46fe639231e7ef))
- A cancelled lane didn't end a block that fails fast ([f332ea9](https://github.com/wavezync/durable/commit/f332ea93739eda34189d4ba8130e9c14f662f34b))
- A cancel dropped the rollback of a run that was waiting to be undone ([5ff36de](https://github.com/wavezync/durable/commit/5ff36de272f8c5ee42af1c3089d76c52477b9413))
- An undo got atom keys when its run failed as it resumed from a parallel block ([b7be7a4](https://github.com/wavezync/durable/commit/b7be7a403c7cc77e55e47491979e69e49a894dc1))
- A run lost right after a jump or a branch on: step ran that step again ([a829f28](https://github.com/wavezync/durable/commit/a829f286431cf7a00b32425cc80787f3b328f9c9))
- A jump could land inside a branch or a parallel block it wasn't in ([1a40ef6](https://github.com/wavezync/durable/commit/1a40ef65bccdd9dca35a73743054199fef9fe381))
- A restarted queue manager left the node stopping for good ([4e4fed3](https://github.com/wavezync/durable/commit/4e4fed35d1ce9b7f1b918c585a0cc535aeda8df3))
- A poll that raised took the queue manager down ([1939d43](https://github.com/wavezync/durable/commit/1939d43a9ecbd3f42cf25dc655c181d1996f713e))
- A killed poller let its queue run over its limit ([b947e70](https://github.com/wavezync/durable/commit/b947e70557730b6dabc291894b28210027e63ecc))
- A worker whose claim was taken over before it began ran the step anyway ([90e7e3d](https://github.com/wavezync/durable/commit/90e7e3d8091c6090f2dc5b13af6cf54c6168c52c))
- Triggering a schedule whose workflow isn't on this node raised ([bfd8842](https://github.com/wavezync/durable/commit/bfd88422c1179a86616d55fe1329c2d2008c8315))
- A start raised when the PubSub was down, after inserting its run ([aca3001](https://github.com/wavezync/durable/commit/aca3001e59e832b2cea1299cf785a59123541e53))
- A task killed as its attempt began left a step row open for ever ([90f99d6](https://github.com/wavezync/durable/commit/90f99d6b653998b788b9e3875125e1bad9ed414f))
- A step whose result was saved before its worker died ran again ([466b2a1](https://github.com/wavezync/durable/commit/466b2a11dc278567e73bf9bb98787d064ddbd3b6))
- A rollback asked for again repeated the undos that had finished ([771ee58](https://github.com/wavezync/durable/commit/771ee580594065a342b2830f64a3984b39c78ab2))
- A node stopping in the middle of a rollback left the run locked ([5c4cd59](https://github.com/wavezync/durable/commit/5c4cd591240e4bcb3bdce2a162459025cccd2612))
- A result taken from a step's row left out what the step put in the context ([26eed43](https://github.com/wavezync/durable/commit/26eed439ce192d6fc19de1fc1ed610399517b01a))
- Two senders of one event were both told it was delivered ([5f88cc1](https://github.com/wavezync/durable/commit/5f88cc1169d1686078e6f7c18fca9ee4741a4465))
- The timeout sweep marked a wait answered in time as timed out ([ee08303](https://github.com/wavezync/durable/commit/ee083031b130efbe39a080bc20e5ba986f9d6a9b))
- A wait that timed out returned its timeout_value as JSON, not as written ([53e6d3b](https://github.com/wavezync/durable/commit/53e6d3b3585eb4a04cb168ada0dfaf42a3d4e219))
- A whole float came back from a save as an integer ([82fd1a9](https://github.com/wavezync/durable/commit/82fd1a9d22efa97d1f56d5fc6f202c8ca2ae41e4))
- Only a wait for input broadcast :workflow_waiting ([6546c7b](https://github.com/wavezync/durable/commit/6546c7be13c42b5f348e12ffda652b8bc4aa38f6))
- Durable.Testing raised BadMapError for an id that names no run ([2922797](https://github.com/wavezync/durable/commit/29227979781f259fc259a836ac22d4d86ca35327))
- A wait the engine couldn't record raised out of the executor ([df6f24c](https://github.com/wavezync/durable/commit/df6f24cfd3db5a4003646edb65d72a185e5b9e27))
- Stats.timeline built a map for every bucket, however many ([6a532a1](https://github.com/wavezync/durable/commit/6a532a1c71bfe4cf461eda26264eb1000fb171c8))
- A start's input could drive the engine through its own context keys ([d28a6ba](https://github.com/wavezync/durable/commit/d28a6ba185a58ae1a153a67dad13b6659d069027))
- A start that replaces the key's holder dropped the rollback of one waiting to be undone ([0420e68](https://github.com/wavezync/durable/commit/0420e68d9d6ba3d3c1b08a599a45ccb33278afad))
- A step written with a do block crashed the compiler ([caabfa3](https://github.com/wavezync/durable/commit/caabfa3439e0ebd490c674a2c6700dc0112d7945))
- A module's default workflow was the last one defined, not the first ([dce424c](https://github.com/wavezync/durable/commit/dce424c5f58d976d57e44c2df21b13396666acba))
- Input/0 was always an empty map in a step ([edd8c17](https://github.com/wavezync/durable/commit/edd8c17e6085605bacebee9fcd2b764d0555059b))
- An atom clause of branch on: stopped matching once the run was reloaded ([f0df284](https://github.com/wavezync/durable/commit/f0df28476f352cd748d166eb41c217716ce4af02))
- A parallel block straight after one that collects its errors raised ([0e655fc](https://github.com/wavezync/durable/commit/0e655fca4a50acf6ba288960a7ae847df4b6aed2))
- A key under both shapes lost its atom after the run was reloaded ([e71bd13](https://github.com/wavezync/durable/commit/e71bd13f6e8c5a9fd0b81b4af1656a7702850df1))

### Refactoring

- Split cancel_run and named_parallel for credo ([b20ab6c](https://github.com/wavezync/durable/commit/b20ab6c65cdf362ff4c438e4ca89444481d6defa))
- Engine state has its own column, out of the run's context ([3fce50f](https://github.com/wavezync/durable/commit/3fce50f52a0a03ba28dbf549b55e2165af3fdccb))

### Documentation

- Don't name a version for the rollback change ([ea903af](https://github.com/wavezync/durable/commit/ea903afae1838b1d70ea4df4341fc3632e6a9a7f))
- Parallel blocks are named; lane options, cancel with rollback, rollback_after ([d043458](https://github.com/wavezync/durable/commit/d04345823a2090d00a06f682b1b20b134766398b))
- Cancel_wait's example called Durable.cancel_wait/2, which doesn't exist ([e2fc21b](https://github.com/wavezync/durable/commit/e2fc21bfb955c1c7617d79f9af91bac6e96aa23b))
- The read functions' tuple and ! forms, and how to upgrade to them ([1d4ea43](https://github.com/wavezync/durable/commit/1d4ea4380eccc7e856132f6370998c7711573972))
- A parent that times out cancels every child, as cancelling it does ([c9dd08c](https://github.com/wavezync/durable/commit/c9dd08c65dac6eaa0cf73057d0cba0fa34033d34))
- The 2.0 upgrade, step by step, and everything else that changed ([2d042a4](https://github.com/wavezync/durable/commit/2d042a46a8122be44bcb889a6a8e60958562cd29))
- The README for 2.0, with examples that survive a reload ([50ab33e](https://github.com/wavezync/durable/commit/50ab33ec0d9b749a574715f6f34cd9bcbd9876f8))
- Waits: cancel_wait, what an answer comes back as, and a second send_event ([68315c8](https://github.com/wavezync/durable/commit/68315c8e04d3fc612a574c45f69419220ceafffc))
- Branch on values as strings, and where a jump can't land ([0edd973](https://github.com/wavezync/durable/commit/0edd973179cef454c3b5c13c82ea4a0d97515a6e))
- Orchestration, keys, parallel, compensations and testing guides for 2.0 ([1a14608](https://github.com/wavezync/durable/commit/1a1460821898f13fee13d807920a1073ddbdb2ac))
- Moduledoc examples that compile, and the read contract as it is ([7956303](https://github.com/wavezync/durable/commit/7956303d409f23da2399e980fdfad944e42239fd))
- Wait_for_approval's spec promised atoms it never returns ([692bc38](https://github.com/wavezync/durable/commit/692bc3819ed7432a95ed40a21bce6b1b205eba3e))
- Guide examples that read the same data before and after a reload ([b0cd6e3](https://github.com/wavezync/durable/commit/b0cd6e3113f72923dcb59d648d9e7a9c03207661))

## [1.5.0](https://github.com/wavezync/durable/compare/durable-v1.4.0...durable-v1.5.0) - 2026-11-09

### Features

- A stopping node hands runs over at the next step ([d34cc8a](https://github.com/wavezync/durable/commit/d34cc8aa52126f97a6fdfff7e925f1f96a3a9743))

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

