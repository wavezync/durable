# Parallel Execution

Run independent pieces of work at the same time and hand what each produced to the next step.

## Lanes

A parallel block has a name and holds lanes. It is map and reduce: each lane does one independent piece of work, and the step after the block reduces what they found. Use it for lookups, scoring, enrichment and other work that doesn't depend on its neighbours. Steps that depend on each other, or that can't be undone, belong in a sequence.

```elixir
workflow "loan_application" do
  step :load_application, fn application -> ... end

  parallel :lookups do
    step :credit, [retry: [max_attempts: 3]], fn application ->
      {:ok, %{score: CreditBureau.score(application["applicant"])}}
    end

    step :fraud, fn application -> ... end

    lane :sanctions do
      step :query, [retry: [max_attempts: 3]], fn application -> ... end
      step :screen, fn application -> ... end
    end
  end

  step :decide, fn %{lookups: %{credit: credit, fraud: fraud, sanctions: sanctions}} = application ->
    {:ok, Map.put(application, :outcome, outcome(credit["score"], fraud["risk"], sanctions["listed"]))}
  end
end
```

- **A lane is its own run.** It retries, sleeps, waits and moves queues like any run, and comes back to the step it stopped at. It holds steps, named branches and named parallel blocks. A `step` written straight in the block is a lane of one step, named after it.
- **Every lane starts from the same data** and sees nothing another lane does.
- **The next step gets what each lane produced under the block's name**, by lane name: `%{lookups: %{credit: %{"score" => 712}, fraud: ..., sanctions: ...}}`. That is the block's collect step; you don't write one. What a lane produced is every key its steps added or changed. The data it was started with is left out, so a large application isn't copied once per lane. A lane's output has been stored, so the keys inside it are strings. A lane can't hand back that it removed a key.
- **A lane that fails fails the block** and stops the other lanes. That is `on_error: :fail_fast`, the default.
- **`Durable.retry/1` on the failed run** puts the lanes that didn't finish back to work where they stopped, including a lane inside a lane and a child workflow a lane was waiting for (`call_workflow`). Lanes that finished aren't run again. A lane stopped in the middle of a step is told at its worker's next heartbeat; retry before that and the step can run once more beside the one still finishing, so keep steps in a lane safe to repeat, as lookups are.
- **Steps are stored under the block and the lane**, as `lookups__sanctions__query`.
- **`compensate:` isn't allowed in a lane.** Put the undo on a step before the block.
- **A rollback waits for stopped lanes.** When a lane fails and the run is rolled back (`on_failure: :rollback`, or `{:rollback, reason}`), the other lanes are told at their workers' next heartbeat, and a step of theirs can finish before that. The undo starts one heartbeat (30 s by default) after the lanes were stopped, so a compensation sees what those steps did. A lane that was only waiting makes the undo wait as well.

### Carrying on when a lane fails

With `on_error: :collect` every lane runs to its end, and the next step is handed each one as `{:ok, output}` or `{:error, reason}`. A failed lane doesn't fail the run; the step decides what it means:

```elixir
parallel :lookups, on_error: :collect do
  step :credit, fn application -> ... end
  step :fraud, fn application -> ... end
  step :sanctions, fn application -> ... end
end

step :decide, fn %{lookups: lookups} = application ->
  case lookups do
    %{credit: {:ok, credit}, fraud: {:ok, fraud}, sanctions: {:ok, %{"listed" => false}}} ->
      {:ok, Map.put(application, :outcome, outcome(credit["score"], fraud["risk"]))}

    %{sanctions: {:error, _down}} ->
      {:ok, Map.put(application, :outcome, "manual_review")}

    _ ->
      {:fail, "lookups failed"}
  end
end
```

The step sees the same pairs however the run got back to it. In the stored run a pair is a two-item list, `["ok", data]` or `["error", reason]`.

### A lane the block can do without

Mark a lane `optional: true` when the decision can be made without it. If it fails, the other lanes carry on, the block doesn't fail, and the next step gets `nil` for that lane:

```elixir
parallel :lookups do
  step :credit, fn application -> ... end

  step :device, [optional: true], fn application -> ... end

  lane :social, optional: true do
    step :find_profiles, fn application -> ... end
    step :rate, fn application -> ... end
  end
end

step :decide, fn %{lookups: %{credit: credit, device: device, social: social}} = application ->
  # device and social are nil if their lookup failed
  ...
end
```

Why it failed stays on the lane's own run, which the dashboard shows. In a block that collects, an optional lane is `{:error, reason}` like any other failed lane. A lane that isn't optional still fails the block.

Give the lane a `default:` and the next step gets that in place of `nil`:

```elixir
step :device, [optional: true, default: %{trust: "unknown"}], fn application -> ... end
```

Like a lane's own output the default has been stored, so the step reads `device["trust"]`. The step can no longer tell a device rated unknown from a lookup that failed; only the lane's run shows that.

### A time limit on a lane

`timeout:` on a `lane` is how long the whole lane may take: every step in it, with their retries, sleeps and waits. A step's own `timeout:` only limits one attempt.

```elixir
parallel :lookups do
  step :credit, fn application -> ... end

  lane :social, optional: true, timeout: seconds(20) do
    step :find_profiles, [retry: [max_attempts: 5]], fn application -> ... end
    step :rate, fn application -> ... end
  end
end
```

Past its limit the lane fails with a `"timeout"` error, like any failed lane: here the block goes on without it. A step that is running is stopped; a lane that is sleeping or waiting is ended by a check that runs once a minute, so it can be up to a minute late. The run's own `timeout:` still applies if it comes first. `Durable.retry/1` gives a lane that timed out its full limit again.

## `into:`

`into:` takes a function that gets the data from before the block and every lane's `{:ok, output}` or `{:error, reason}`, and returns what the run carries on with: `{:ok, data}`, `{:error, reason}` or `{:goto, step, data}`. Every lane runs to its end, and nothing is put under the block's name.

```elixir
parallel :lookups, into: fn application, lanes ->
  case lanes do
    %{credit: {:ok, credit}, fraud: {:ok, fraud}} ->
      {:ok, Map.put(application, :outcome, outcome(credit["score"], fraud["risk"]))}

    _ ->
      {:goto, :manual_review, application}
  end
end do
  step :credit, fn application -> ... end
  step :fraud, fn application -> ... end
end
```

Prefer `on_error: :collect` and a step. A step is retried, logged and shown like any other; the function is none of those.

## Child workflows and waits in a lane

A lane is its own run, so it can do anything a run can: retry, snooze, `sleep`, `wait_for_event`, `wait_for_input` or `call_workflow`. The block waits for it without holding a worker.

```elixir
parallel :checks do
  step :identity, fn application ->
    case call_workflow(MyApp.VerifyIdentity, %{"applicant" => application["applicant"]}, ref: :identity) do
      {:ok, result} -> {:ok, %{verified: result["verified"]}}
      {:error, reason} -> {:error, reason}
    end
  end

  step :employer, fn application ->
    answer = wait_for_event("employer_confirmed")
    {:ok, %{employed: answer["employed"]}}
  end
end
```

To send a lane an event or an input, use the lane's own id:

```elixir
employer = Enum.find(Durable.list_children(run_id), &(&1.current_step == "checks__employer"))
Durable.send_event(employer.id, "employer_confirmed", %{"employed" => true})
```

See the [Orchestration Guide](orchestration.md) for more on `call_workflow`.

## How it works

1. Each lane becomes a run of its own, on the block's queue. A step with a `queue:` moves the lane there when it is reached, as in any run.
2. Each lane starts from the data the block was given.
3. The block's run waits without holding a worker.
4. When the lanes are done, what each produced goes under the block's name, or to `into:`.
5. The run carries on at the next step.

## Undoing a parallel block

`compensate:` isn't allowed on a step in a lane, and it's a compile error to try: a lane that finished isn't undone when the run later fails. If lanes have effects to undo, put the compensation on a step before the block. It runs however far the block got, so have it check what actually happened, by an idempotency key from the run's input for example.

## Upgrading from 1.5

Before 1.6 a block could be written with no name, `parallel do`. That form is gone, and is a compile error that says to name the block.

| Before | Now |
|---|---|
| `parallel do` | `parallel :lookups do` |
| `parallel_results()`, `parallel_result(:credit)`, the `__results__` key | the next step's data: `%{lookups: %{credit: ...}}` |
| `on_error: :complete_all` | `on_error: :collect` |
| `step :credit, returns: :score` | name the step for what it returns |
| a step returned its whole data | a lane hands back the keys it added or changed, with string keys |
| steps stored as `parallel_<id>__credit` | `lookups__credit` |

A run that was in the middle of an unnamed block when the app was upgraded can't carry on: finish or cancel those first.
