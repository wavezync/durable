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

  attr :workflow, :map, required: true
  attr :family, :map, required: true
  attr :base_path, :string, required: true

  def children_tab(assigns) do
    assigns =
      assigns
      |> assign(:step_lookup, parent_step_lookup(assigns.family))
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
        <div class="font-mono text-[10px] uppercase tracking-widest text-muted-foreground">
          Parent execution
        </div>
        <.link
          navigate={DPath.workflow_tab(@base_path, @family.parent.id, :flow)}
          class="flex items-center gap-3 group"
        >
          <Core.status_pill status={@family.parent.status} />
          <div class="flex flex-col leading-tight min-w-0 flex-1">
            <span class="font-mono text-[13px] text-foreground group-hover:text-primary transition-colors truncate">
              {@family.parent.workflow_name}
            </span>
            <span class="font-mono text-[10px] text-muted-foreground">
              {short(@family.parent.id)}
            </span>
          </div>
          <span class="text-[11px] text-muted-foreground font-mono">
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
        <div class="font-mono text-[10px] uppercase tracking-widest text-muted-foreground">
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
      navigate={DPath.workflow_tab(@base_path, @member.id, :flow)}
      class={[
        "flex items-center gap-3 px-4 py-2.5 hover:bg-accent/50 transition-colors",
        @member.id == @workflow.id && "bg-primary/[0.04]"
      ]}
    >
      <Core.status_pill status={@member.status} />
      <div class="flex flex-col leading-tight min-w-0 flex-1">
        <div class="flex items-center gap-2 min-w-0">
          <span class="font-mono text-xs text-foreground truncate">
            {Map.get(@step_lookup, @member.id) |> humanize_step_name()}
          </span>
          <span
            :if={@member.id == @workflow.id}
            class="font-mono text-[9px] uppercase tracking-widest text-primary"
          >
            viewing
          </span>
        </div>
        <span class="font-mono text-[10px] text-muted-foreground">
          {short(@member.id)}
        </span>
      </div>
      <div :if={duration(@member)} class="text-numeric text-[11px] text-muted-foreground">
        {duration(@member)}
      </div>
      <Core.icon name="chevron-right" class="h-3.5 w-3.5 text-muted-foreground" />
    </.link>
    """
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  defp parent_step_lookup(%{root: nil}), do: %{}

  defp parent_step_lookup(%{root: root}) when is_map(root) do
    case get_in(root.context || %{}, ["__parallel_children"]) do
      m when is_map(m) ->
        Map.new(m, fn {child_id, meta} ->
          {child_id, meta["step_name"] || meta[:step_name]}
        end)

      _ ->
        %{}
    end
  end

  defp parent_step_lookup(_), do: %{}

  defp family_members(_workflow, %{all_descendants: descendants}) when is_list(descendants),
    do: descendants

  defp family_members(_workflow, %{children: children}) when is_list(children), do: children
  defp family_members(_workflow, _), do: []

  defp current_step_name(workflow, step_lookup) do
    Map.get(step_lookup, workflow.id) |> humanize_step_name()
  end

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
       when not is_nil(started) and not is_nil(completed) do
    seconds = DateTime.diff(completed, started, :second)
    format_seconds(seconds)
  end

  defp duration(_), do: nil

  defp format_seconds(s) when s < 60, do: "#{s}s"
  defp format_seconds(s) when s < 3600, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  defp format_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

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
