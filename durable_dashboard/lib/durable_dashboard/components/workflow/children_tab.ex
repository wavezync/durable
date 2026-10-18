defmodule DurableDashboard.Components.Workflow.ChildrenTab do
  @moduledoc """
  Family tab — exposes the parent / child structure that the parallel
  primitive in Durable's runtime uses to fan a workflow out across
  multiple `WorkflowExecution` rows.

  Layout:

    * **Parent card** — when viewing a child, surfaces the root execution
      with its status + the step the current child handled.
    * **Children list** — every direct + sibling child in the family,
      grouped by status, each with the parallel step name it ran, the
      child's own status pill, duration if recorded, and a deeplink.

  Hidden entirely when the family has neither parent nor children — most
  workflows are flat, and the tab strip stays clean for them.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Path, as: DPath
  alias DurableDashboard.Trace

  attr :workflow, :map, required: true
  attr :family, :map, required: true
  attr :steps, :list, default: [], doc: "the family's step executions, to name what a child ran"
  attr :base_path, :string, required: true

  def children_tab(assigns) do
    assigns =
      assigns
      |> assign(:step_lookup, step_lookup(assigns.family, assigns.steps))
      |> assign(:family_members, family_members(assigns.workflow, assigns.family))

    ~H"""
    <div class="space-y-6">
      <.parent_card
        :if={@family[:parent]}
        workflow={@workflow}
        family={@family}
        base_path={@base_path}
        step_lookup={@step_lookup}
      />

      <%= if @family_members == [] do %>
        <Core.empty_state
          icon="information-circle"
          title="No related executions"
          description="This workflow runs in a single execution — no parent and no spawned children. The Flow tab shows everything that ran."
        />
      <% else %>
        <.family_list
          workflow={@workflow}
          members={@family_members}
          base_path={@base_path}
          step_lookup={@step_lookup}
        />
      <% end %>
    </div>
    """
  end

  attr :workflow, :map, required: true
  attr :family, :map, required: true
  attr :base_path, :string, required: true
  attr :step_lookup, :map, required: true

  defp parent_card(assigns) do
    ~H"""
    <Core.card padding="md">
      <div class="flex flex-col gap-2">
        <div class="text-xs text-muted-foreground">
          Parent execution
        </div>
        <.link
          navigate={DPath.execution_tab(@base_path, @family.parent.id, :graph)}
          class="flex items-center gap-3 group"
        >
          <Core.status_pill status={@family.parent.status} />
          <div class="flex flex-col leading-tight min-w-0 flex-1">
            <span class="font-mono text-[13px] text-foreground group-hover:text-primary transition-colors truncate">
              {@family.parent.workflow_name}
            </span>
            <span
              class="font-mono text-[10px] text-muted-foreground"
              data-tip="Parent run id"
              data-tip-meta={@family.parent.id}
            >
              {short(@family.parent.id)}
            </span>
          </div>
          <span
            class="text-[11px] text-muted-foreground font-mono"
            data-tip="The parent's step this run was started for"
          >
            this child ran <span class="text-primary">{current_step_name(@workflow, @step_lookup)}</span>
          </span>
          <Core.icon
            name="chevron-right"
            class="h-4 w-4 text-muted-foreground group-hover:text-primary transition-colors"
          />
        </.link>
      </div>
    </Core.card>
    """
  end

  attr :workflow, :map, required: true
  attr :members, :list, required: true
  attr :base_path, :string, required: true
  attr :step_lookup, :map, required: true

  defp family_list(assigns) do
    ~H"""
    <Core.card padding="none">
      <div class="flex items-center justify-between border-b border-border px-4 py-2.5">
        <div class="text-xs text-muted-foreground">
          Family executions ({length(@members)})
        </div>
        <div class="flex items-center gap-2 text-[10px] text-muted-foreground font-mono">
          <span :for={{label, count} <- status_summary(@members)} class="inline-flex items-center gap-1">
            <span class={["size-1 rounded-full", status_dot(label)]} />
            {count} {label}
          </span>
        </div>
      </div>
      <ol class="divide-y divide-border">
        <li :for={member <- @members}>
          <.member_row
            member={member}
            workflow={@workflow}
            base_path={@base_path}
            step_lookup={@step_lookup}
          />
        </li>
      </ol>
    </Core.card>
    """
  end

  attr :member, :map, required: true
  attr :workflow, :map, required: true
  attr :base_path, :string, required: true
  attr :step_lookup, :map, required: true

  defp member_row(assigns) do
    ~H"""
    <.link
      navigate={DPath.execution_tab(@base_path, @member.id, :graph)}
      class={[
        "flex items-center gap-3 px-4 py-2.5 hover:bg-accent/50 transition-colors",
        @member.id == @workflow.id && "bg-primary/[0.04]"
      ]}
    >
      <Core.status_pill status={@member.status} />
      <div class="flex flex-col leading-tight min-w-0 flex-1">
        <div class="flex items-center gap-2 min-w-0">
          <span
            class="font-mono text-xs text-foreground truncate"
            data-tip="The parent's step that started this run"
          >
            {step_of(@member, @step_lookup) |> humanize_step_name()}
          </span>
          <span
            :if={@member.id == @workflow.id}
            class="text-xs text-primary"
          >
            viewing
          </span>
        </div>
        <span
          class="font-mono text-[10px] text-muted-foreground"
          data-tip="Run id"
          data-tip-meta={@member.id}
        >
          {short(@member.id)}
        </span>
      </div>
      <div
        :if={duration(@member)}
        class="text-numeric text-[11px] text-muted-foreground"
        data-tip-title="Duration"
        data-tip="From starting to finishing"
        data-tip-meta={span_meta(@member)}
      >
        {duration(@member)}
      </div>
      <Core.icon name="chevron-right" class="h-3.5 w-3.5 text-muted-foreground" />
    </.link>
    """
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  # Which step each child ran: the parent step that started it (from the
  # root's context) or, since a finished parallel block drops its key, the
  # first step the child executed itself.
  defp step_lookup(family, steps) do
    ran =
      steps
      |> Enum.sort_by(& &1.inserted_at, DateTime)
      |> Enum.reverse()
      |> Map.new(&{&1.workflow_id, &1.step_name})

    Map.merge(ran, parent_step_lookup(family))
  end

  defp parent_step_lookup(%{root: nil}), do: %{}

  defp parent_step_lookup(%{root: root}) when is_map(root) do
    for key <- ["__parallel_children", "__call_children"],
        {child_id, meta} <- Map.get(root.context || %{}, key) || %{},
        into: %{},
        do: {child_id, meta["step_name"] || meta[:step_name]}
  end

  defp parent_step_lookup(_), do: %{}

  defp family_members(_workflow, %{all_descendants: descendants}) when is_list(descendants),
    do: descendants

  defp family_members(_workflow, %{children: children}) when is_list(children), do: children
  defp family_members(_workflow, _), do: []

  defp current_step_name(workflow, step_lookup) do
    workflow |> step_of(step_lookup) |> humanize_step_name()
  end

  defp step_of(run, step_lookup), do: Map.get(step_lookup, run.id) || Map.get(run, :current_step)

  defp humanize_step_name(nil), do: "(no step)"

  defp humanize_step_name(name) when is_binary(name) do
    case String.split(name, "__") do
      [_qualifier, _clause, original] -> original
      [_qualifier, original] -> original
      _ -> name
    end
  end

  defp humanize_step_name(other), do: to_string(other)

  defp short(nil), do: "—"
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp duration(%{started_at: started, completed_at: completed})
       when not is_nil(started) and not is_nil(completed),
       do: Trace.format_ms(DateTime.diff(completed, started, :millisecond))

  defp duration(_), do: nil

  defp span_meta(%{started_at: started, completed_at: completed}),
    do:
      "#{Calendar.strftime(started, "%H:%M:%S")} → #{Calendar.strftime(completed, "%H:%M:%S")} UTC"

  defp status_summary(members) do
    members
    |> Enum.group_by(&to_string(&1.status))
    |> Enum.map(fn {label, list} -> {label, length(list)} end)
    |> Enum.sort_by(fn {label, _} -> status_order(label) end)
  end

  defp status_order("running"), do: 0
  defp status_order("waiting"), do: 1
  defp status_order("pending"), do: 2
  defp status_order("completed"), do: 3
  defp status_order("failed"), do: 4
  defp status_order("cancelled"), do: 5
  defp status_order(_), do: 99

  defp status_dot("running"), do: "bg-success"
  defp status_dot("waiting"), do: "bg-warning"
  defp status_dot("completed"), do: "bg-success/70"
  defp status_dot("failed"), do: "bg-destructive"
  defp status_dot("cancelled"), do: "bg-muted-foreground"
  defp status_dot(_), do: "bg-muted-foreground/40"
end
