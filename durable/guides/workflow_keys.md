# Workflow Keys

Start a workflow at most once per key, even when the producer sends the same work again.

## Why Keys?

Producers send duplicates. A webhook is delivered twice, a client retries after a timeout, and an editor saves the same article five times in a minute. Without a key, each of those starts a run and the article is processed again. A check in your own code ("is there already a run for article 42?") races with the other node doing the same check.

A workflow key makes the database answer that question. At most one run of a workflow holds a given key; starting it again returns that run instead of creating another.

## Quick Example

```elixir
defmodule MyApp.ProcessArticle do
  use Durable
  use Durable.Context

  # Process each article once. Try again only if the last attempt failed.
  workflow "process_article", reuse: :after_failure do
    step :fetch do
      article = MyApp.CMS.get_article!(input()["id"])
      put_context(:body, article.body)
    end

    step :summarize do
      MyApp.Summaries.write(input()["id"], get_context(:body))
    end
  end
end
```

```elixir
{:ok, run_id} = Durable.start(MyApp.ProcessArticle, %{"id" => 42}, key: "article:42")

# The producer sends it again: same run, nothing new is created
{:ok, ^run_id} = Durable.start(MyApp.ProcessArticle, %{"id" => 42}, key: "article:42")
```

## How It Works

- **One holder per key.** Among the runs of one workflow, at most one *holds* a key. A start that finds the key held returns the holder (or an error, see below) and creates nothing: no run, no `:workflow_started` broadcast, nothing run inline. The exception is `on_duplicate: :cancel_existing`, which replaces the holder with a new run.
- **Keys are scoped per workflow.** `"article:42"` on `process_article` and on `index_article` are two different keys.
- **A run that's still going always holds its key.** Pending, running, waiting (sleep, events, input) and compensating runs keep it, including while a step is between retry attempts.
- **After the run finishes, `reuse:` decides** whether the next start may take the key or gets the finished run back.

Status isn't part of the uniqueness rule. A key changes hands only when a new start asks for it, when a retry takes it back, when you release it, or when the holder is pruned. Moving a run between statuses (claiming it, recovering it from a dead node, cancelling it) never frees a key or fails on one.

## Choosing `reuse:`

Set it on the workflow:

```elixir
workflow "process_article", reuse: :after_failure do
```

| Holder's status | `:after_close` (default) | `:after_failure` | `:never` |
|-----------------|--------------------------|------------------|----------|
| Pending, running, waiting, compensating | taken | taken | taken |
| Completed | free | taken | taken |
| Failed, cancelled, compensated, compensation failed | free | free | taken |

*Taken* means the start gets the holder back. *Free* means the start creates a new run, which becomes the holder.

- **`:after_close`**: one run at a time per key. Use it for "don't run two syncs of account 7 at once".
- **`:after_failure`**: each item succeeds once. Use it for "process each article once, but let a failed attempt be tried again".
- **`:never`**: each key runs once, ever (until the run is pruned). Use it for "send invoice INV-2208 exactly once".

`reuse:` can't be passed to `Durable.start/3`: every producer of a workflow gets the same answer for a key. It's read when a start runs, so changing it on the workflow applies to existing runs at the next start.

## What a Duplicate Returns

`on_duplicate:` picks the answer when the key is taken. Set a default on the workflow, and override it per call:

```elixir
workflow "send_invoice", reuse: :never, on_duplicate: :error do
```

```elixir
Durable.start(SendInvoice, %{"id" => "INV-2208"}, key: "invoice:INV-2208")
#=> {:error, {:key_taken, "3f2a91c4-…"}}

Durable.start(SendInvoice, %{"id" => "INV-2208"}, key: "invoice:INV-2208", on_duplicate: :use_existing)
#=> {:ok, "3f2a91c4-…"}
```

| `on_duplicate:` | Key free | Key taken by a run that's still going |
|-----------------|----------|---------------------------------------|
| `:use_existing` (default) | `{:ok, new_id}` | `{:ok, holder_id}` |
| `:error` | `{:ok, new_id}` | `{:error, {:key_taken, holder_id}}` |
| `:cancel_existing` | `{:ok, new_id}` | cancels the holder, `{:ok, new_id}` |
| `:run_again` | `{:ok, new_id}` | one run waits behind the holder, `{:ok, waiting_id}` |
| `{:send_event, name}` | `{:ok, new_id}` | sends the input to the holder, `{:ok, holder_id}` |

`:cancel_existing`, `:run_again` and `{:send_event, name}` are about a holder that's still going; see [Updates That Arrive While a Run Is Going](#updates-that-arrive-while-a-run-is-going). A finished holder that `reuse:` keeps answers both with `{:error, {:key_taken, holder_id}}`, since there's nothing to cancel or send to.

Other results:

- `{:error, %Ecto.Changeset{}}`: the key isn't a string of 1 to 255 bytes. `""` is rejected rather than treated as "no key"; `nil` means no key.
- `{:error, :key_contended}`: the key changed hands three times while this start ran. That takes several other starts and retries racing on the same key at once; trying again is safe.

## Choosing a Key

You choose the key, so it says what "the same work" means:

- `"article:42"`: each article once.
- `"article:42:rev:7"`: each revision of an article once. A new revision is new work.
- `"sync:account:7"` with `reuse: :after_close`: never two syncs of one account at a time.

Pass ids in the input, not content. A run started from `%{"id" => 42}` that fetches the article in its first step processes the latest version, even if the article was edited after the start. A run started with the article body processes the body it was given.

## Inside Your Own Transaction

A start can share a transaction with your own writes, so a run exists only if the article was saved:

```elixir
Repo.transaction(fn ->
  article = Repo.insert!(changeset)
  {:ok, _run_id} = Durable.start(ProcessArticle, %{"id" => article.id}, key: "article:#{article.id}")
  article
end)
```

- A duplicate doesn't raise, and doesn't leave the transaction unusable: your later writes still work.
- If the transaction rolls back, the new run and its key roll back with it.
- Under `REPEATABLE READ` or `SERIALIZABLE`, two transactions starting the same key at the same moment can make one of them fail with a serialization error, as Postgres does for any conflicting insert at those levels. Retry the transaction.

## Retry, Rerun and Releasing a Key

**`Durable.retry/2`** resumes a failed run. If that run still holds its key, nothing changes. If a newer run took the key while it was failed, the retry takes it back by the same rules as a start: when the newer run has finished and `reuse:` lets it go. Otherwise the retry is refused, and the failed run stays as it was:

```elixir
Durable.retry(old_id)
#=> {:error, {:key_taken, newer_id}}
```

**`Durable.rerun/2`** starts a fresh copy of a finished run with the same key, following the start rules. It returns `{:error, {:key_taken, holder_id}}` instead of the holder, so you see why nothing ran.

**`Durable.release_key/2`** lets a finished run's key go, for processing an item again on purpose, even under `reuse: :never`:

```elixir
:ok = Durable.release_key(invoice_run_id, by: "ops@example.com")
{:ok, new_id} = Durable.rerun(invoice_run_id)
```

The released run keeps its history and its `key`. A run that's still going returns `{:error, :not_finished}` (cancel it first), and a run that doesn't hold a key returns `{:error, :no_key}`.

**Pruning** deletes finished runs past your retention, and a deleted holder's key is free again. Under `reuse: :never`, the retention period is how long "never" lasts.

## Updates That Arrive While a Run Is Going

With `on_duplicate: :use_existing`, a start that arrives while the holder is still going gets the holder back, and its input is dropped. Durable records it, so you can see it happened:

- `Durable.Activity` gets a `"key_duplicate"` event on the holder, with `input_changed: true` and the new `input`.
- The dashboard's run page says how many times the key was added again, and shows the dropped input as a diff.

If the newer input matters, pick one of these:

| You want | Use |
|----------|-----|
| The run to read the latest data when it gets there | Pass ids, not content (see Choosing a Key) |
| Every revision processed | Put the revision in the key |
| The newest input to win, starting over | `on_duplicate: :cancel_existing` |
| One more run after the holder, with the newest input | `on_duplicate: :run_again` |
| The running run to take the new input itself | `on_duplicate: {:send_event, name}` |
| A burst of updates to become one run with the last input | `debounce:` |
| The producer to decide | `on_duplicate: :error` |

### Replace the Running Run: `:cancel_existing`

```elixir
Durable.start(ProcessArticle, %{"id" => 42, "rev" => 8}, key: "article:42", on_duplicate: :cancel_existing)
#=> {:ok, new_id}
```

The holder is cancelled and gives up its key in one step, and a new run starts with the new input. It works under any `reuse:`, `:never` included, because the holder hadn't finished. The cancel is the same as `Durable.cancel/2`: a step already running is stopped at its next heartbeat, no later step runs, and compensations don't run. The cancelled run's error says which run replaced it. A compensating holder can't be cancelled, so that start returns `{:error, {:key_taken, holder_id}}`. This is Temporal's TERMINATE_EXISTING, and Inngest's singleton `cancel` mode.

### Run Once More After It: `:run_again`

```elixir
workflow "rebuild_index", on_duplicate: :run_again do
```

The account's index is being rebuilt when the user edits again. With `:use_existing` that start is dropped, and the index misses the edit. With `:run_again` it leaves one run waiting behind the holder, without the key:

```elixir
Durable.start(RebuildIndex, %{"v" => 2}, key: "account:7")  #=> {:ok, waiting_id}
Durable.start(RebuildIndex, %{"v" => 3}, key: "account:7")  #=> {:ok, waiting_id}, now with v3
```

However many starts arrive, one run waits, with the newest input. When the holder ends, however it ends, the waiting run takes the key and runs. So no start is lost, one run holds the key, and at most one waits behind it.

- `reuse:` still decides. A failed holder lets the waiting run go under the default `:after_close`. If `reuse:` keeps the key (`:after_failure` and the holder completed), the waiting run is cancelled, and its error says why. `:run_again` with `reuse: :never` fails the compile.
- A holder that no worker has picked up yet takes the newer input itself, as with `debounce:`, so nothing waits behind a run that hasn't started.
- If another start took the key between the holder ending and the waiting run starting, the waiting run waits behind that run instead.
- The waiting run's `timeout:` counts from when it takes the key. Its `runs_after_id` is the run it waits for.

In Oban this takes a job that finishes, checks for new work and snoozes to go again.

### Hand the Input to the Running Run: `{:send_event, name}`

```elixir
workflow "process_article", reuse: :after_failure do
  step :fetch do
    put_context(:article, MyApp.CMS.get_article!(input()["id"]))
  end

  step :publish do
    MyApp.Feeds.publish(get_context(:article))
  end

  # A later save during processing arrives here.
  step :catch_up do
    case wait_for_event("article_updated", timeout: minutes(5), timeout_value: :none) do
      :none -> :ok
      %{"rev" => rev} -> MyApp.Feeds.refresh(input()["id"], rev)
    end
  end
end
```

```elixir
Durable.start(ProcessArticle, %{"id" => 42, "rev" => 8},
  key: "article:42",
  on_duplicate: {:send_event, "article_updated"}
)
#=> {:ok, holder_id}
```

The first start's input is the run's input. Later starts while it's going send their input to it as the event `"article_updated"`, like Temporal's Signal-With-Start:

- If the run is waiting for that event, it gets it and resumes.
- If it isn't waiting yet, the event is kept and delivered when the run reaches `wait_for_event("article_updated")`, so an update that arrives mid-step isn't lost.
- A run gets one event per name (`wait_for_event` returns the first one it received). If several were kept by the time it waits, it gets the newest. Events sent after the run already got one are kept but never read.

`Durable.send_event/4` does the same keeping with `buffer: true`, for events you send yourself.

### Collapse a Burst: `debounce:`

```elixir
workflow "index_article", debounce: [period: seconds(30), timeout: minutes(5)] do
```

A start with a key waits `period` before it runs. Each start with the same key in that time gives the waiting run the newer input and restarts the wait, so five saves in a minute become one run with the last save. `timeout` caps the wait: the run starts at most that long after the first start, even if saves keep coming. Without `timeout`, a steady stream of saves keeps it waiting.

Once a worker has picked the run up, the next start is an ordinary duplicate and `on_duplicate:` decides. Starts without a key aren't debounced. A workflow `timeout:` counts from when the debounced run is due, not from the first start. This is Inngest's debounce.

## Watching Keys

- **Activity**: `Durable.Activity.list(kinds: ["key_duplicate"])`. The kinds are `"key_duplicate"` (its `outcome` says what the start did: `use_existing`, `error`, `cancel_existing`, `run_again` (with `runs_after` when a run waits), `send_event` or `debounced`), `"key_handed_off"` (a start took the key from a finished or replaced run), `"key_released"` and `"key_retaken"` (a retry took its key back). Each has `details.key` and `details.workflow`. Activity is kept for a week.
- **Stats**: `Durable.Stats.keys(workflow: "process_article")` returns keys held, re-adds by outcome, dropped inputs, hand-offs, re-adds over time and the keys re-added most.
- **Telemetry**: `[:durable, :key, :duplicate]`, `[:durable, :key, :handoff]` and `[:durable, :key, :release]`. See `Durable.Telemetry`.
- **Query**: `Durable.list_executions(key: "article:42")` returns every run started with the key; the holder has `holds_key: true`.
- **Query**: `Durable.Query.list_keys(workflow_name: "process_article")` lists keys with their holder, how many runs used each, and re-adds in the last day.
- **Dashboard**: the Keys page lists every key and its holder. A run's Key view lists its re-adds and every run with its key, and the workflow page has a Keys section. Search Runs with `key:article:42`.

## Cron Schedules

A schedule fires on time even if its last run hasn't finished, so a cleanup every 5 minutes that takes 6 starts a second copy beside the first. Give the schedule a key:

```elixir
@schedule cron: "*/5 * * * *", key: "cleanup"
workflow "cleanup" do
```

(or `Durable.schedule(MyApp.Cleanup, "*/5 * * * *", key: "cleanup")`). Every fire starts with that key, so a fire while the last run still holds it follows the workflow's `on_duplicate:`. With the default `:use_existing` it starts nothing, and Activity records a `"key_duplicate"`. With `:error` the fire is skipped the same way, and it doesn't count toward the schedule's failures. `Durable.trigger_schedule/2` uses the key too.

## Things to Know

- **Keys aren't inherited.** Parallel branches and `call_workflow` children start without a key. A cron schedule fire starts without one unless the schedule has a `key:` (next section).
- **Runs started before the upgrade** have no key and never hold one.
- **Upgrading** adds two columns and three indexes (`mix durable.gen.upgrade`, then migrate). Creating the indexes scans the runs table and blocks inserts into it while it runs, so on a large table, deploy at a quiet time.
- **One key, one workflow.** There's no lookup by key across workflows.

## Coming From Oban or Temporal

- **Temporal**: a key is a Workflow ID. `reuse:` is the Workflow ID reuse policy (`:after_close` is ALLOW_DUPLICATE, `:after_failure` is ALLOW_DUPLICATE_FAILED_ONLY, `:never` is REJECT_DUPLICATE). `on_duplicate:` is the conflict policy (`:use_existing` is USE_EXISTING, `:error` is FAIL, `:cancel_existing` is TERMINATE_EXISTING), and `{:send_event, name}` is Signal-With-Start. Pruning plays the part of the retention period.
- **Inngest**: `debounce:` is Inngest's debounce, `:cancel_existing` is singleton's `cancel` mode, and `:use_existing` is singleton's `skip`. Inngest's idempotency key lasts 24 hours; a key lasts until its run is pruned.
- **Oban**: `unique:` is checked against a list of job states and a time `period`. A key has neither: an unfinished run always holds it, and `reuse:` decides after it finishes, so a run moving between states can't let a duplicate in or collide with one.
