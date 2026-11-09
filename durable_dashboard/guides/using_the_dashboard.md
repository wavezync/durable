# Using the dashboard

`durable_dashboard` is a web console for Durable. It shows what your workflows
are doing and lets you act on them: retry a failed run, answer an approval,
pause a queue. It runs inside your Phoenix app, so there's nothing else to
deploy.

This guide covers setup, what each page is for, and how to do the common jobs.

## Set it up

Add the package, then mount it at the top level of your router, outside any
`scope` or `pipe_through`:

```elixir
# mix.exs
{:durable_dashboard, "~> 1.2"}

# router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  use DurableDashboard.Router, mount: "/dashboard"
end
```

Three more things are worth doing before anyone relies on it.

**Give Durable a PubSub**, so pages update as runs change. Use your app's, or
`pubsub: :start` to have Durable start its own. Without one, most pages won't
update until you reload them. Queues & nodes polls, so it stays current either
way.

```elixir
{Durable, repo: MyApp.Repo, pubsub: MyApp.PubSub}
```

**Put it behind your login.** The dashboard has no authentication of its own.
Run your auth with `on_mount`:

```elixir
use DurableDashboard.Router,
  mount: "/dashboard",
  on_mount: [{MyAppWeb.UserAuth, :ensure_authenticated}]
```

**Decide who can change things.** Without a resolver, everyone who can open the
dashboard is a viewer and nothing can be changed from it. A resolver maps your
users to a level:

```elixir
use DurableDashboard.Router,
  mount: "/dashboard",
  resolver: MyAppWeb.DurableResolver

defmodule MyAppWeb.DurableResolver do
  @behaviour DurableDashboard.Access

  @impl true
  def resolve_user(conn), do: conn.assigns[:current_user]

  @impl true
  def resolve_access(%{role: :admin}), do: :admin
  def resolve_access(%{role: :ops}), do: :operator
  def resolve_access(_user), do: :viewer
end
```

| Level | Can |
|---|---|
| `:viewer` | See everything, change nothing |
| `:operator` | Retry, rerun and cancel runs. Answer inputs and send events. Pause and resume queues. Run a schedule now. Release a workflow key |
| `:admin` | All of that, plus turn schedules on and off and prune on demand |

The server checks the level on every action, and each one emits
`[:durable_dashboard, :action]` with the action, the user and the run ids, so
you can keep an audit trail.

Two other router options: `:durable` if your instance has its own `name:`, and
`:live_socket_path` if your endpoint's LiveView socket isn't at `/live`.

## Find your way around

The sidebar groups pages by what you came to do. Press ⌘K (Ctrl+K on Windows
and Linux) from anywhere to jump to a page, workflow, schedule or run. Paste
four or more characters of a run id and it's found even if it's old. Paste a
workflow key (anything with a `:`) to see who holds it.

| Page | Use it to |
|---|---|
| **Overview** | See health over the last hour to 30 days: what's failing and why, queue pressure, the slowest steps, a live feed |
| **Runs** | Find runs, see why each is where it is, act on them one at a time or in bulk |
| **Workflows** | Compare workflows by runs, failure rate, duration and retries. Open one for its structure and per-step numbers |
| **Inbox** | Answer inputs people are waiting on, send events runs are blocked on, see what's sleeping |
| **Keys** | See every workflow key, who holds it, and what was re-added or dropped |
| **Queues & nodes** | See load, backlog and wait per queue, pause a queue, check which nodes are alive |
| **Schedules** | Check cron schedules, run one now, turn one on or off |
| **Telemetry** | Check your metrics reporter is attached and which events are firing |
| **Settings** | Check the schema is up to date and how this instance is configured |

Filters and selected views live in the URL, so you can paste a link to a search,
a run, or one step's error into a chat.

## What a status means

| Shows | Means | Look at |
|---|---|---|
| **Pending** | Queued for a worker. Partway through a run it says which step is next | The second line says what's holding it: a slot on a step's queue, or the run it's waiting behind |
| **Retrying** | A step failed and runs again when its backoff ends | The countdown, attempts used ("2 of 5") and the error |
| **Snoozed** | A step asked to run again later. Doesn't use an attempt | How long, and the reason the step gave |
| **Running** | A worker is on it now | Which step, and on which node |
| **Waiting** | Paused on a sleep, an event or a person | The banner, and the Inbox |
| **Completed** | Finished every step | |
| **Failed** | A step ran out of attempts or returned `{:fail, reason}`, or the run passed its `timeout:` | The error and its stack. Retry picks up from that step |
| **Compensated** | A step failed and the steps before it were undone | Rerun starts fresh. Retry is off, because earlier results were undone |
| **Compensation failed** | Undoing the earlier steps failed too | The compensation steps. Some effects may still be in place |
| **Cancelled** | Stopped on purpose: by a person, a step, its parent, or a newer start with the same key | The reason. Cancelled runs don't count as failures |

## Common jobs

### A run failed

Start on the **Failed** tab of Runs, or on Overview, which groups failing
workflows by error so one bad deploy shows up as one line.

The run page says what happened in a sentence. **Show error** opens the step's
error with its stack, your app's frames shown and library frames folded. From
there:

- **Retry from step** resumes at the failed step. Steps that finished don't run
  again.
- **Rerun** starts a new run from the first step with the same input, linked
  back to this one.
- **Rerun with edited input** does the same after you've fixed the input.

If the run has a workflow key and another run holds it now, the page says so
and says what would unblock it.

### A run isn't moving

Check its status against the table above, then open **Queues & nodes**. A run
stays Pending when:

- the queue is paused, which is shown in the queue's state
- no live node polls that queue, which the queue says in amber
- every slot is busy, which shows as a full meter in amber

The nodes table shows which nodes are heartbeating and which queues each one
polls. The Operations list below it records recovered runs, fenced workers and
queue pauses for the last day.

### Someone has to approve something

Open **Inbox**. Its count in the sidebar is how many inputs are waiting. Each
task shows the run, the prompt, what happens if nobody answers, and the form its
input type needs. Answering resumes the run.

**Waiting for events** lists every event a run is blocked on, with a form to
send one by hand. That's useful when a webhook never arrived.

### Find runs for one customer or order

Type in the query bar on Runs and press Enter. Each term becomes a tag you can
remove, and terms combine.

| Type | Finds |
|---|---|
| `9f2c41a0` | A run by id, or the start of one |
| `workflow:process_order` | Runs of one workflow |
| `status:failed,cancelled` | Runs in any of these states |
| `since:24h` | Runs started in the last 15m, 1h, 24h, 7d or 30d |
| `step:ship_order` | Runs that are on, or stopped at, this step |
| `error:503` or `error:"rate limited"` | Text anywhere in the error |
| `input.order_id:ORD-1042` | An exact value in the input, with dots for nested fields |
| `key:article:42` | Runs started with this workflow key |
| `tag:account:7` | Runs started with this tag. Repeat it to require several |
| `schedule:nightly_report` | Runs a schedule started |

A plain word searches the error. Click a tag chip on a row to filter by it.

### Act on many runs

Tick rows on Runs and a bar appears with what fits the selection: **Retry**
failed runs, **Rerun** finished ones, **Release** keys held by finished runs,
**Cancel** open ones. Each action skips the selected runs it doesn't apply to,
and the bar says how many it will touch. A selection is the rows on the page, so
changing the page or filter starts it over.

### Stop a queue during an incident

Press **Pause** on the queue in Queues & nodes. It applies on every node until
someone resumes it. Runs already running carry on, and new ones wait.

### Check a schedule

Schedules shows each one's last runs as marks, when it fires next, and whether
it's failing. A schedule that keeps failing to start gets turned off, and says
so in red with the last error. **Run now** starts a run with its input and
doesn't change its timing.

## Reading a run

The top of the page is the status, the actions that fit it, a banner when
there's something to know, and the facts: when it started, how long it's taken,
attempts, what triggered it, its queue, tags and key.

| View | Shows |
|---|---|
| **Trace** | One row per step on a timeline, with a bar per attempt. The gaps are named: backoff, snoozed, wait. Click a row to inspect it |
| **Graph** | The workflow's shape with this run's state on it, including branches not taken and steps that never ran |
| **Logs** | What the steps logged |
| **Context** | The run's input and data |
| **Family** | Its parent and child runs, when it has any |
| **Key** | What happened to its workflow key, when it has one: re-adds, dropped inputs, and every run that used it |

The step inspector has Error, Input, Output, Logs and Attempts. A step that
snoozed or cancelled has no Error tab, because neither is a failure. The reason
is under Attempts.

## What it reads, and from where

Numbers on Overview, Workflows and Queues come from Postgres, so they hold
across nodes. Two things are per node or limited in time:

- The event counts on Telemetry cover this node, over the last five minutes.
- Operations and the re-add history on Keys go back seven days.

Finished runs disappear when your retention deletes them. See
[Running in production](https://durable.wavezync.com/docs/production/) for how to
set that.
