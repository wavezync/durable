# Testing

Test workflows by running them inline in the test process. `Durable.Testing`
runs a workflow, and everything it spawns, until nothing is left to do, then
gives you the run to assert on.

## Setup

Turn queue processing off in `config/test.exs`. Queue workers would otherwise
race your tests for the same runs:

```elixir
config :durable, disable_queue_processing: true
```

Durable still starts from your supervision tree as usual. Then import the
helpers, for example in your `DataCase`:

```elixir
defmodule MyApp.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Durable.Testing
      # ...
    end
  end
end
```

Runs execute in the test process, so they share the test's Ecto sandbox and
everything is rolled back when the test ends.

## Running a Workflow

`run_workflow/3` starts a workflow and drains it. It returns the run as a
`%Durable.Storage.Schemas.WorkflowExecution{}`:

```elixir
test "fulfils an order" do
  run = run_workflow(MyApp.OrderWorkflow, %{"order_id" => 42})

  assert_status(run, :completed)
  assert %{"order_id" => 42, "shipped" => true} = run.context
end
```

It takes the same options as `Durable.start/3`, such as `workflow:` to pick
a workflow in a module that defines several.

Context and input are stored as JSON, so read them with string keys.

`assert_status/2` checks `:completed`, `:failed`, `:waiting`, `:cancelled`,
`:compensated` or any other status. When it fails, it prints the run's
current step and error:

```
Expected workflow run 0f3c… to be :completed, got :failed
current step: "charge"
error: %{"message" => "card declined", "type" => "error"}
```

## Steps

`assert_step/3` checks how a step's latest attempt ended (`:completed` by
default) and returns its `%StepExecution{}`:

```elixir
assert_step(run, :reserve)
assert_step(run, :charge, :failed)

assert %{"invoice_id" => _} = assert_step(run, :invoice).output
```

Steps inside `parallel` and `branch` blocks are matched by their own name, so
`assert_step/3` also tells you which branch ran:

```elixir
run = run_workflow(MyApp.FulfilmentWorkflow, %{"type" => "digital"})

assert_step(run, :send_download_link)
```

`steps/2` lists every step execution, oldest first, with one row per attempt.

## Parallel Blocks

`drain/2` runs every branch of a parallel block, then the steps after it.
Unless the block has an `into:` callback, the branch results are stored under
`__results__`:

```elixir
run = run_workflow(MyApp.OnboardingWorkflow, %{})

assert %{"__results__" => %{"send_email" => ["ok", _]}} = run.context
```

## Waits

A run that waits for input or an event stops at `:waiting`. Resume it with the
regular API, then drain it again:

```elixir
test "a manager approves the expense" do
  run = run_workflow(MyApp.ExpenseWorkflow, %{"amount" => 500})

  assert_status(run, :waiting)
  assert_waiting_for_input(run, "manager_approval")

  :ok = Durable.provide_input(run.id, "manager_approval", %{"approved" => true})

  run
  |> drain()
  |> assert_status(:completed)
end
```

Events work the same way, with `assert_waiting_for_event/2` and
`Durable.send_event/3`.

`sleep/1` and `schedule_at/1` don't hold a test up: drain ends them right
away, so a run that sleeps for a day finishes in milliseconds.

## Retries

Retries skip their backoff during a drain. `attempt` on the step's latest row
says how many attempts it took:

```elixir
test "retries a flaky gateway" do
  expect(MyApp.GatewayMock, :charge, 2, fn _ -> {:error, :timeout} end)
  expect(MyApp.GatewayMock, :charge, fn _ -> {:ok, "ch_1"} end)

  run = run_workflow(MyApp.PaymentWorkflow, %{"amount" => 100})

  assert_status(run, :completed)
  assert assert_step(run, :charge).attempt == 3
end
```

Steps run in the test process, so Mox expectations apply without
`allow/3`.

## Compensations

A failure that's rolled back ends as `:compensated`, or as
`:compensation_failed` if a compensation failed too. Compensation steps are
recorded as `compensate_<name>`:

```elixir
run = run_workflow(MyApp.BookTripWorkflow, %{})

assert_status(run, :compensated)
assert_step(run, :book_hotel, :failed)
assert_step(run, :compensate_cancel_flight)
```

## Child Workflows

Drain also runs the child workflows that a run starts, with `call_workflow/3`
or `start_workflow/3`, and resumes the parent once a child is done. Use
`Durable.list_children/2` to inspect them.

## Scheduled Workflows

A scheduled workflow is an ordinary workflow, so test it with
`run_workflow/3`. To test the schedule itself, create it and trigger it:

```elixir
{:ok, _} = Durable.schedule(MyApp.ReportWorkflow, "0 9 * * *", name: "daily_report")
{:ok, id} = Durable.trigger_schedule("daily_report")

id
|> drain()
|> assert_status(:completed)
```

## Limits

- Wait timeouts (`timeout:` on `wait_for_input/2` and the other waits) don't
  fire during a drain, because the timeout worker only runs with the queue
  enabled.
- A workflow's `timeout:` uses the real clock, so drain doesn't skip ahead to
  it.
- `drain/2` raises if the Durable instance has queue processing enabled. To
  test with real queue workers, start Durable with the queue on and poll
  `Durable.get_execution/2` until the run finishes.

## Multiple Instances

Every helper takes a `durable:` option naming the Durable instance, which
defaults to `Durable`:

```elixir
run_workflow(MyApp.OrderWorkflow, %{}, durable: MyApp.Durable)
assert_status(run, :completed, durable: MyApp.Durable)
```
