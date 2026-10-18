defmodule DurableDashboard.Live.InputsLive do
  @moduledoc """
  The inbox: runs paused on a person, an event, or the clock.

    * **Needs input** — a task list beside the selected task, with the form
      its input type calls for (approval, choice, form, free text). Answering
      calls `Durable.Wait.provide_input/4` and the run resumes.
    * **Waiting for events** — every external event a run is blocked on, with
      a send form that calls `Durable.Wait.send_event/4`. Internal events
      (names starting with `__`, e.g. parallel completion) are hidden.
    * **Sleeping** — runs in `sleep/1` or `schedule_at/1`, and when they wake.

  Answering and sending need `:operator` access.
  """

  use Phoenix.LiveView

  import Ecto.Query

  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WorkflowExecution}
  alias DurableDashboard.Access
  alias DurableDashboard.Components.Charts
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @tabs [{"input", "Needs input"}, {"events", "Waiting for events"}, {"sleep", "Sleeping"}]
  @limit 200
  @refresh_ms 1_000

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]

    if connected?(socket) do
      if durable_config = Durable.Config.get_safe(config.durable) do
        # The inputs topic arrives through `InboxBadge`, which every page mounts.
        DurablePubSub.subscribe(durable_config, DurablePubSub.workflows_topic(durable_config))
      end
    end

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: config.durable,
       page_title: "Inbox",
       wants_input_events: true,
       breadcrumbs: [%{label: "Inbox"}],
       refresh_pending?: false,
       sending: nil,
       notice: nil,
       action_error: nil
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    tab = if params["tab"] in Enum.map(@tabs, &elem(&1, 0)), do: params["tab"], else: "input"

    {:noreply,
     socket
     |> assign(current_path: URI.parse(uri).path, tab: tab, selected_id: params["id"])
     |> load()}
  end

  @impl true
  def handle_info(
        {:durable_event, _kind, _payload},
        %{assigns: %{refresh_pending?: true}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({:durable_event, _kind, _payload}, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, refresh_pending?: true)}
  end

  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh_pending?: false) |> load()}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ============================================================================
  # Answering inputs
  # ============================================================================

  @impl true
  def handle_event("decide", params, socket),
    do: respond(socket, approval(params["decision"] == "approve", params, socket))

  def handle_event("answer", params, socket) do
    case answer(socket.assigns.selected, params) do
      {:ok, data} -> respond(socket, data)
      {:error, message} -> {:noreply, assign(socket, action_error: message)}
    end
  end

  # ============================================================================
  # Sending events
  # ============================================================================

  def handle_event("compose", %{"id" => id}, socket),
    do:
      {:noreply,
       assign(socket,
         sending: Enum.find(socket.assigns.events, &(&1.id == id)),
         action_error: nil
       )}

  def handle_event("close-compose", _params, socket),
    do: {:noreply, assign(socket, sending: nil, action_error: nil)}

  def handle_event("send", %{"payload" => json}, socket) do
    event = socket.assigns.sending

    with {:ok, payload} <- decode_payload(json),
         :ok <-
           Access.perform(socket, :operator, :send_event, [event.workflow_id], fn ->
             Durable.Wait.send_event(event.workflow_id, event.event_name, payload,
               durable: socket.assigns.durable
             )
           end) do
      notice =
        "Sent #{event.event_name} to #{run_label(event.workflow)} — it resumes on the next poll."

      {:noreply, socket |> assign(sending: nil, notice: notice, action_error: nil) |> load()}
    else
      {:error, reason} -> {:noreply, assign(socket, action_error: describe_error(reason))}
    end
  end

  defp respond(socket, data) do
    input = socket.assigns.selected

    result =
      Access.perform(socket, :operator, :provide_input, [input.workflow_id], fn ->
        Durable.Wait.provide_input(input.workflow_id, input.input_name, data,
          durable: socket.assigns.durable
        )
      end)

    case result do
      :ok ->
        notice = "Answered #{input.input_name} on #{run_label(input.workflow)} — the run resumes."

        # Off the answered request: the next one opens, and the URL says so.
        {:noreply,
         socket
         |> assign(notice: notice, action_error: nil)
         |> push_patch(to: DPath.inputs(socket.assigns.base_path) <> "?tab=input")}

      {:error, reason} ->
        {:noreply, assign(socket, action_error: describe_error(reason))}
    end
  end

  defp approval(approved?, params, socket) do
    %{"approved" => approved?}
    |> put_present("comment", String.trim(params["comment"] || ""))
    |> put_present("by", socket.assigns[:user])
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc false
  # Turns the submitted form into the value the run receives, per input type.
  def answer(%{input_type: :single_choice}, %{"choice" => choice}) when choice != "",
    do: {:ok, choice}

  def answer(%{input_type: :single_choice}, _params), do: {:error, "Pick one option."}

  def answer(%{input_type: :multi_choice}, params), do: {:ok, Map.get(params, "choices", [])}

  def answer(%{input_type: :free_text}, %{"text" => text}), do: {:ok, text}

  def answer(%{input_type: :form, fields: fields}, params) do
    values = Map.get(params, "fields", %{})

    Enum.reduce_while(fields || [], {:ok, %{}}, fn field, {:ok, acc} ->
      name = to_string(field["name"])

      case cast_field(field, Map.get(values, name)) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, message} -> {:halt, {:error, "#{field_label(field)}: #{message}"}}
      end
    end)
  end

  def answer(_input, _params), do: {:error, "This input type can't be answered here."}

  defp cast_field(field, value) when value in [nil, ""] do
    if field["required"] && field["type"] not in ["boolean", "checkbox"],
      do: {:error, "required"},
      else: {:ok, if(field["type"] in ["boolean", "checkbox"], do: false)}
  end

  defp cast_field(%{"type" => type}, value) when type in ["boolean", "checkbox"],
    do: {:ok, value == "true"}

  defp cast_field(%{"type" => "number"}, value) do
    case Integer.parse(value) do
      {int, ""} ->
        {:ok, int}

      _ ->
        case Float.parse(value) do
          {float, ""} -> {:ok, float}
          _ -> {:error, "not a number"}
        end
    end
  end

  defp cast_field(_field, value), do: {:ok, value}

  defp decode_payload(json) do
    case Jason.decode(if(String.trim(json) == "", do: "{}", else: json)) do
      {:ok, payload} -> {:ok, payload}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp describe_error(:forbidden), do: "You don't have permission to do that."

  defp describe_error(:not_found),
    do: "It's no longer waiting — someone may have answered it already."

  defp describe_error(:invalid_json), do: "The payload isn't valid JSON."
  defp describe_error(other), do: "That didn't work: #{inspect(other)}"

  # ============================================================================
  # Data
  # ============================================================================

  defp load(socket) do
    case Durable.Config.get_safe(socket.assigns.durable) do
      nil ->
        assign(socket, inputs: [], events: [], sleeping: [], counts: %{}, selected: nil)

      config ->
        inputs = Durable.Repo.all(config, inputs_query())
        selected = Enum.find(inputs, &(&1.id == socket.assigns.selected_id)) || List.first(inputs)

        assign(socket,
          inputs: inputs,
          selected: selected,
          events:
            if(socket.assigns.tab == "events",
              do: Durable.Repo.all(config, events_query()),
              else: []
            ),
          sleeping:
            if(socket.assigns.tab == "sleep",
              do: Durable.Repo.all(config, sleeping_query()),
              else: []
            ),
          counts: %{
            "input" => count(config, inputs_query()),
            "events" => count(config, events_query()),
            "sleep" => count(config, sleeping_query())
          }
        )
    end
  end

  defp inputs_query do
    from(p in PendingInput,
      where: p.status == :pending,
      order_by: [asc_nulls_last: p.timeout_at, asc: p.inserted_at],
      limit: @limit,
      preload: [:workflow]
    )
  end

  defp events_query do
    from(p in PendingEvent,
      where: p.status == :pending and not fragment("starts_with(?, '__')", p.event_name),
      order_by: [asc_nulls_last: p.timeout_at, asc: p.inserted_at],
      limit: @limit,
      preload: [:workflow]
    )
  end

  defp sleeping_query do
    from(w in WorkflowExecution,
      where: w.status == :waiting and not is_nil(w.scheduled_at),
      order_by: [asc: w.scheduled_at],
      limit: @limit
    )
  end

  defp count(config, query) do
    Durable.Repo.one(
      config,
      query
      |> exclude(:order_by)
      |> exclude(:preload)
      |> exclude(:limit)
      |> select([r], count(r.id))
    )
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        tabs: @tabs,
        can_operate?: Access.allowed?(assigns.access, :operator),
        inbox_path: DPath.inputs(assigns.base_path)
      )

    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
      durable={@durable} inbox_count={@inbox_count}
    >
      <Core.heading
        level={1}
        subtitle="Runs paused on a person, an event, or the clock. Answer here and the run resumes."
      >
        Inbox
      </Core.heading>

      <nav class="mt-5 flex gap-1 border-b border-border" aria-label="Inbox views">
        <.link
          :for={{key, label} <- @tabs}
          patch={"#{@inbox_path}?tab=#{key}"}
          class={[
            "-mb-px flex items-center gap-2 border-b-2 px-3 pb-2.5 pt-1 text-[13px] font-medium",
            if(@tab == key,
              do: "border-primary text-foreground",
              else: "border-transparent text-subtle-foreground hover:text-foreground"
            )
          ]}
          aria-current={@tab == key && "page"}
          data-tip={tab_tip(key)}
        >
          {label}
          <span class="rounded-full bg-secondary px-1.5 font-mono text-[11px] text-subtle-foreground">
            {Map.get(@counts, key, 0)}
          </span>
        </.link>
      </nav>

      <p :if={@notice} class="mt-4 rounded-md bg-success/10 px-3 py-2 text-xs text-success" role="status">
        {@notice}
      </p>
      <p :if={@action_error} class="mt-4 text-xs text-destructive" role="alert">{@action_error}</p>

      <.input_tab :if={@tab == "input"} {assigns} />
      <.events_tab :if={@tab == "events"} {assigns} />
      <.sleep_tab :if={@tab == "sleep"} {assigns} />
    </Layouts.app>
    """
  end

  defp input_tab(assigns) do
    ~H"""
    <Core.empty_state
      :if={@inputs == []}
      icon="inbox"
      title="Nothing waiting on a person"
      description="Runs that call wait_for_input/2, wait_for_approval/2 and friends show up here while they wait."
      class="mt-4"
    />
    <div :if={@inputs != []} class="mt-4 grid gap-4 lg:grid-cols-[minmax(280px,360px)_minmax(0,1fr)]">
      <ul class="min-w-0 overflow-hidden rounded-[10px] border border-border bg-card">
        <li :for={input <- @inputs} class="border-b border-border last:border-b-0">
          <.link
            patch={"#{@inbox_path}?tab=input&id=#{input.id}"}
            class={[
              "flex flex-col gap-1 px-4 py-3 hover:bg-accent",
              @selected && @selected.id == input.id && "bg-secondary"
            ]}
            aria-current={@selected && @selected.id == input.id && "true"}
          >
            <span class="flex items-center gap-2 text-xs">
              <span data-tip-title={type_label(input.input_type)} data-tip={"The run receives " <> receives(input)}>
                <Core.badge kind="primary">{type_label(input.input_type)}</Core.badge>
              </span>
              <span
                :if={input.timeout_at}
                class="ml-auto text-muted-foreground"
                data-tip-title="If nobody answers"
                data-tip={on_timeout(input)}
              >
                times out <Core.relative_time at={input.timeout_at} />
              </span>
            </span>
            <span class="line-clamp-2 text-[13px] font-medium">{input.prompt || input.input_name}</span>
            <span class="truncate text-xs text-muted-foreground">
              {workflow_name(input.workflow)} · {input.input_name} · asked <Core.relative_time at={input.inserted_at} />
            </span>
          </.link>
        </li>
      </ul>

      <.task :if={@selected} input={@selected} base_path={@base_path} can_operate?={@can_operate?} />
    </div>
    """
  end

  attr :input, :map, required: true
  attr :base_path, :string, required: true
  attr :can_operate?, :boolean, required: true

  defp task(assigns) do
    ~H"""
    <article id={"task-#{@input.id}"} class="min-w-0 self-start rounded-[10px] border border-border bg-card p-5 lg:sticky lg:top-6">
      <p class="text-xs text-muted-foreground">
        {workflow_name(@input.workflow)} ·
        <.link
          navigate={DPath.execution(@base_path, @input.workflow_id)}
          class="font-mono text-primary hover:underline"
          data-tip="Open the run that's waiting"
          data-tip-meta={@input.workflow_id}
        >
          {short(@input.workflow_id)}
        </.link>
        · step <span class="font-mono" data-tip="The step that asked · the run carries on from it">{@input.step_name}</span>
      </p>
      <h2 class="mt-1.5 text-lg font-semibold leading-snug">{@input.prompt || @input.input_name}</h2>
      <p class="mt-2 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
        <span data-tip-title={type_label(@input.input_type)} data-tip={"The run receives " <> receives(@input)}>
          <Core.badge kind="primary">{type_label(@input.input_type)}</Core.badge>
        </span>
        <span>Asked <Core.relative_time at={@input.inserted_at} /></span>
        <span data-tip-title="If nobody answers" data-tip={on_timeout(@input)}>
          · {timeout_sentence(@input)}
        </span>
      </p>

      <dl :if={facts(@input.metadata) != []} class="mt-4 grid grid-cols-[max-content_minmax(0,1fr)] gap-x-6 gap-y-1.5 rounded-md bg-secondary/60 px-4 py-3 text-[13px]">
        <%= for {k, v} <- facts(@input.metadata) do %>
          <dt class="text-muted-foreground">{k}</dt>
          <dd class="min-w-0 break-words font-mono text-xs leading-5">{v}</dd>
        <% end %>
      </dl>

      <p :if={!@can_operate?} class="mt-5 text-xs text-muted-foreground">
        You can see this task but not answer it — answering needs operator access.
      </p>

      <fieldset disabled={!@can_operate?} class="mt-5">
        <.response_form input={@input} />
      </fieldset>

      <details class="mt-5 text-xs">
        <summary class="cursor-pointer text-muted-foreground hover:text-foreground">What the run receives</summary>
        <p class="mt-2 text-muted-foreground">
          <span class="font-mono">wait_for_*("{@input.input_name}")</span> returns {receives(@input)}
        </p>
      </details>
    </article>
    """
  end

  attr :input, :map, required: true

  defp response_form(%{input: %{input_type: :approval}} = assigns) do
    ~H"""
    <form id={"answer-#{@input.id}"} phx-submit="decide" class="flex flex-col gap-3">
      <label class="flex flex-col gap-1.5 text-xs font-medium">
        <span>Comment <span class="font-normal text-muted-foreground">(optional)</span></span>
        <textarea id={"#{@input.id}-comment"} name="comment" rows="2" class={field_class()}></textarea>
      </label>
      <div class="flex justify-end gap-2">
        <Core.button
          kind="destructive"
          type="submit"
          name="decision"
          value="reject"
          data-tip="The run resumes with approved: false"
        >
          Reject
        </Core.button>
        <Core.button
          kind="primary"
          type="submit"
          name="decision"
          value="approve"
          data-tip="The run resumes with approved: true"
        >
          Approve
        </Core.button>
      </div>
    </form>
    """
  end

  defp response_form(%{input: %{input_type: type}} = assigns)
       when type in [:single_choice, :multi_choice] do
    ~H"""
    <form id={"answer-#{@input.id}"} phx-submit="answer" class="flex flex-col gap-2">
      <p class="text-xs font-medium">{if @input.input_type == :single_choice, do: "Pick one", else: "Pick any"}</p>
      <label
        :for={choice <- @input.fields || []}
        class="flex cursor-pointer items-center gap-3 rounded-md border border-border px-3 py-2.5 hover:bg-accent has-[:checked]:border-primary has-[:checked]:bg-primary/5"
      >
        <input
          id={"#{@input.id}-#{choice["value"]}"}
          type={if @input.input_type == :single_choice, do: "radio", else: "checkbox"}
          name={if @input.input_type == :single_choice, do: "choice", else: "choices[]"}
          value={choice["value"]}
          class="accent-[var(--primary)]"
        />
        <span class="flex flex-col leading-tight">
          <span class="text-[13px] font-medium">{choice["label"] || choice["value"]}</span>
          <span :if={choice["hint"] || choice["description"]} class="text-xs text-muted-foreground">
            {choice["hint"] || choice["description"]}
          </span>
        </span>
      </label>
      <div class="mt-1 flex justify-end">
        <Core.button kind="primary" type="submit">Submit</Core.button>
      </div>
    </form>
    """
  end

  defp response_form(%{input: %{input_type: :form}} = assigns) do
    ~H"""
    <form id={"answer-#{@input.id}"} phx-submit="answer" class="grid gap-3 sm:grid-cols-2">
      <label :for={field <- @input.fields || []} class={["flex flex-col gap-1.5 text-xs font-medium", field["type"] == "textarea" && "sm:col-span-2"]}>
        <span>
          {field_label(field)}
          <span :if={!field["required"]} class="font-normal text-muted-foreground">(optional)</span>
        </span>
        <.form_field field={field} id={"#{@input.id}-#{field["name"]}"} />
      </label>
      <div class="flex justify-end sm:col-span-2">
        <Core.button kind="primary" type="submit">Submit form</Core.button>
      </div>
    </form>
    """
  end

  defp response_form(assigns) do
    ~H"""
    <form id={"answer-#{@input.id}"} phx-submit="answer" class="flex flex-col gap-3">
      <label class="flex flex-col gap-1.5 text-xs font-medium">
        Response
        <textarea id={"#{@input.id}-text"} name="text" rows="4" class={field_class()}></textarea>
      </label>
      <div class="flex justify-end">
        <Core.button kind="primary" type="submit">Submit</Core.button>
      </div>
    </form>
    """
  end

  attr :field, :map, required: true
  attr :id, :string, required: true

  defp form_field(%{field: %{"type" => "select"}} = assigns) do
    ~H"""
    <select id={@id} name={"fields[#{@field["name"]}]"} required={@field["required"]} class={field_class()}>
      <option value="">Choose…</option>
      <option :for={opt <- @field["options"] || []} value={opt}>{opt}</option>
    </select>
    """
  end

  defp form_field(%{field: %{"type" => "textarea"}} = assigns) do
    ~H"""
    <textarea id={@id} name={"fields[#{@field["name"]}]"} rows="3" required={@field["required"]} class={field_class()}></textarea>
    """
  end

  defp form_field(%{field: %{"type" => type}} = assigns) when type in ["boolean", "checkbox"] do
    ~H"""
    <input id={@id} type="checkbox" name={"fields[#{@field["name"]}]"} value="true" class="size-4 accent-[var(--primary)]" />
    """
  end

  defp form_field(assigns) do
    ~H"""
    <input
      id={@id}
      type={input_type(@field["type"])}
      step={@field["type"] == "number" && "any"}
      name={"fields[#{@field["name"]}]"}
      required={@field["required"]}
      class={field_class()}
    />
    """
  end

  defp events_tab(assigns) do
    ~H"""
    <article :if={@sending} class="mt-4 rounded-[10px] border border-primary/40 bg-card p-5">
      <h2 class="text-sm font-semibold">
        Send <span class="font-mono">{@sending.event_name}</span> to {run_label(@sending.workflow)}
      </h2>
      <form phx-submit="send" class="mt-3 flex flex-col gap-3">
        <label class="flex flex-col gap-1.5 text-xs font-medium">
          Payload (JSON)
          <textarea name="payload" rows="5" class={[field_class(), "font-mono"]}>{"{}"}</textarea>
        </label>
        <p class="text-xs text-muted-foreground">
          Same as calling Durable.send_event/3 from your app. The run resumes on the next poll.
        </p>
        <div class="flex justify-end gap-2">
          <Core.button phx-click="close-compose">Cancel</Core.button>
          <Core.button kind="primary" type="submit">Send event</Core.button>
        </div>
      </form>
    </article>

    <Charts.panel title="Waiting for events" sub="external events only — internal ones are hidden" class="mt-4">
      <Core.empty_state
        :if={@events == []}
        icon="inbox"
        title="No run is waiting for an event"
        description="Runs that call wait_for_event/2, wait_for_any/2 or wait_for_all/2 show up here."
      />
      <div :if={@events != []} class="thin-scroll overflow-x-auto">
        <table class="w-full border-collapse">
          <thead>
            <tr class="border-y border-border text-xs text-muted-foreground">
              <th class="px-4 py-2 text-left font-medium" data-tip="The event name the step waits on">Waiting for</th>
              <th class="px-4 py-2 text-left font-medium">Run</th>
              <th class="px-4 py-2 text-left font-medium">Step</th>
              <th class="px-4 py-2 text-right font-medium" data-tip="When the step started waiting">Since</th>
              <th class="px-4 py-2 text-right font-medium" data-tip="When the step stops waiting if no event comes">Times out</th>
              <th class="px-4 py-2 text-left font-medium" data-tip="What the step gets if it times out">On timeout</th>
              <th :if={@can_operate?} class="px-4 py-2"><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={e <- @events} class="h-[46px] border-b border-border last:border-b-0 hover:bg-accent">
              <td class="px-4">
                <span class="font-mono">{e.event_name}</span>
                <span :if={e.wait_type != :single} data-tip={wait_type_tip(e.wait_type)}>
                  <Core.badge class="ml-1.5">{e.wait_type} of</Core.badge>
                </span>
              </td>
              <td class="px-4"><.run_cell run={e.workflow} base_path={@base_path} /></td>
              <td class="px-4 font-mono text-xs">{e.step_name}</td>
              <td class="px-4 text-right text-xs text-muted-foreground"><Core.relative_time at={e.inserted_at} /></td>
              <td class="px-4 text-right text-xs">
                <Core.relative_time :if={e.timeout_at} at={e.timeout_at} />
                <span :if={!e.timeout_at} class="text-muted-foreground">never</span>
              </td>
              <td class="px-4 font-mono text-xs text-subtle-foreground">
                {if e.timeout_at, do: "resumes with #{timeout_value(e.timeout_value)}", else: "—"}
              </td>
              <td :if={@can_operate?} class="px-4 text-right">
                <Core.button
                  size="sm"
                  phx-click="compose"
                  phx-value-id={e.id}
                  data-tip="Deliver it by hand, as Durable.send_event/3 would"
                >
                  Send event…
                </Core.button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Charts.panel>
    """
  end

  defp sleep_tab(assigns) do
    ~H"""
    <Charts.panel title="Sleeping" sub="runs in sleep/1 or schedule_at/1 — they wake on their own" class="mt-4">
      <Core.empty_state
        :if={@sleeping == []}
        icon="clock"
        title="No run is sleeping"
        description="Runs that call sleep/1 or schedule_at/1 show up here until they wake."
      />
      <div :if={@sleeping != []} class="thin-scroll overflow-x-auto">
        <table class="w-full border-collapse">
          <thead>
            <tr class="border-y border-border text-xs text-muted-foreground">
              <th class="px-4 py-2 text-left font-medium">Run</th>
              <th class="px-4 py-2 text-left font-medium">Step</th>
              <th class="px-4 py-2 text-right font-medium" data-tip="When the step went to sleep">Asleep since</th>
              <th class="px-4 py-2 text-right font-medium" data-tip="When the run picks up again by itself">Wakes</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- @sleeping} class="h-[46px] border-b border-border last:border-b-0 hover:bg-accent">
              <td class="px-4"><.run_cell run={run} base_path={@base_path} /></td>
              <td class="px-4 font-mono text-xs">{run.current_step}</td>
              <td class="px-4 text-right text-xs text-muted-foreground"><Core.relative_time at={run.updated_at} /></td>
              <td class="px-4 text-right text-xs"><Core.relative_time at={run.scheduled_at} /></td>
            </tr>
          </tbody>
        </table>
      </div>
    </Charts.panel>
    """
  end

  attr :run, :any, required: true
  attr :base_path, :string, required: true

  defp run_cell(assigns) do
    ~H"""
    <.link :if={@run} navigate={DPath.execution(@base_path, @run.id)} class="flex flex-col leading-tight">
      <span class="text-[13px] font-medium">{@run.workflow_name}</span>
      <span class="font-mono text-xs text-muted-foreground" data-tip="Run id" data-tip-meta={@run.id}>
        {short(@run.id)}
      </span>
    </.link>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp type_label(:approval), do: "Approval"
  defp type_label(:single_choice), do: "Choice"
  defp type_label(:multi_choice), do: "Multiple choice"
  defp type_label(:form), do: "Form"
  defp type_label(:free_text), do: "Text"
  defp type_label(other), do: to_string(other)

  defp tab_tip("input"),
    do: "Runs waiting on wait_for_input or wait_for_approval · answer them here"

  defp tab_tip("events"), do: "Runs waiting on wait_for_event · send the event to resume them"
  defp tab_tip("sleep"), do: "Runs in sleep/1 or schedule_at/1 · they wake by themselves"

  defp on_timeout(%{on_timeout: :fail}), do: "The run fails"

  defp on_timeout(input),
    do: "The step gets #{timeout_value(input.timeout_value)} instead, and the run carries on"

  defp wait_type_tip(:any), do: "Resumes on the first of these events to arrive"
  defp wait_type_tip(:all), do: "Resumes once every one of these events has arrived"
  defp wait_type_tip(_type), do: nil

  defp timeout_sentence(%{timeout_at: nil}), do: "never times out"

  defp timeout_sentence(%{on_timeout: :fail} = input),
    do: "times out #{relative(input.timeout_at)}, then the run fails"

  defp timeout_sentence(input),
    do:
      "times out #{relative(input.timeout_at)}, then resumes with #{timeout_value(input.timeout_value)}"

  defp relative(at) do
    seconds = DateTime.diff(at, DateTime.utc_now())
    if seconds <= 0, do: "now", else: "in " <> DurableDashboard.Format.ms(seconds * 1_000)
  end

  # Timeout values are stored wrapped so atoms and scalars survive JSONB.
  defp timeout_value(nil), do: "nil"
  defp timeout_value(%{"__atom__" => atom}), do: ":#{atom}"
  defp timeout_value(%{"__value__" => value}), do: Jason.encode!(value)
  defp timeout_value(value), do: Jason.encode!(value)

  defp receives(%{input_type: :approval}),
    do: ~s(%{"approved" => true | false}, plus "comment" and "by" when given.)

  defp receives(%{input_type: :single_choice}), do: "the chosen option's value, as a string."
  defp receives(%{input_type: :multi_choice}), do: "a list of the chosen values."
  defp receives(%{input_type: :form}), do: "a map of field name to value; numbers are parsed."
  defp receives(_input), do: "the text, as a string."

  defp facts(nil), do: []

  defp facts(metadata) when is_map(metadata) do
    Enum.map(metadata, fn {k, v} ->
      {k |> to_string() |> String.replace("_", " ") |> String.capitalize(), fact_value(v)}
    end)
  end

  defp facts(_metadata), do: []

  defp fact_value(v) when is_binary(v), do: v
  defp fact_value(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp fact_value(v), do: Jason.encode!(v)

  defp field_label(field), do: field["label"] || to_string(field["name"])

  defp input_type(type) when type in ["number", "email", "date", "url"], do: type
  defp input_type(_type), do: "text"

  defp field_class do
    "w-full rounded-md border border-input bg-background px-2.5 py-1.5 text-[13px] font-normal " <>
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-60"
  end

  defp workflow_name(%WorkflowExecution{workflow_name: name}), do: name
  defp workflow_name(_workflow), do: "—"

  defp run_label(%WorkflowExecution{} = run), do: "#{run.workflow_name} · #{short(run.id)}"
  defp run_label(_run), do: "the run"

  defp short(nil), do: "—"
  defp short(id), do: String.slice(id, 0, 8)
end
