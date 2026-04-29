defmodule DurableDashboard.Components.Workflow.FamilyChip do
  @moduledoc """
  Compact header affordance that surfaces the workflow's family
  relationships at a glance:

    * **Child views** render a `↑ Child of <short_id>` link that
      navigates to the parent's flow page.
    * **Parents with children** render a `<N> children` chip that, on
      click, expands to a small dropdown listing each child with its
      status pill, the parallel-step it ran, and a deeplink. Implemented
      via the native `<details>` element so it stays accessible without
      a Phoenix.LiveView round-trip.

  Every chip is rendered as a horizontal row of plain links — small,
  monospaced, and visually subordinate to the workflow name + status
  pill that already live in the header.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Path, as: DPath

  @doc """
  Render the appropriate chip for the workflow's family position.

  `family` is shaped like `WorkflowLive.load_family/2` returns:
  `%{root, parent, children, siblings, all_descendants, related_ids}`.
  """
  attr :family, :map, required: true
  attr :workflow, :map, required: true
  attr :base_path, :string, required: true
  attr :parent_step_lookup, :map, default: %{}

  def family_chip(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <.parent_link :if={@family[:parent]} parent={@family.parent} base_path={@base_path} />
      <.children_popover
        :if={@family[:children] != []}
        children={@family.children}
        base_path={@base_path}
        parent_step_lookup={@parent_step_lookup}
      />
    </div>
    """
  end

  attr :parent, :map, required: true
  attr :base_path, :string, required: true

  defp parent_link(assigns) do
    ~H"""
    <.link
      navigate={DPath.workflow_tab(@base_path, @parent.id, :flow)}
      class={[
        "inline-flex items-center gap-1.5 h-6 px-2 rounded-sm",
        "border border-border bg-card text-foreground/80",
        "font-mono text-[10px] uppercase tracking-wider",
        "hover:border-primary/60 hover:text-primary transition-colors"
      ]}
      title={"Open parent " <> @parent.id}
    >
      <Core.icon name="chevron-left" class="h-3 w-3" />
      <span>parent</span>
      <span class="text-muted-foreground">·</span>
      <span>{short(@parent.id)}</span>
    </.link>
    """
  end

  attr :children, :list, required: true
  attr :base_path, :string, required: true
  attr :parent_step_lookup, :map, required: true

  defp children_popover(assigns) do
    ~H"""
    <details class="group/family relative">
      <summary class={[
        "list-none cursor-pointer inline-flex items-center gap-1.5 h-6 px-2 rounded-sm",
        "border border-border bg-card text-foreground/80",
        "font-mono text-[10px] uppercase tracking-wider",
        "hover:border-primary/60 hover:text-primary transition-colors",
        "select-none"
      ]}>
        <span class="size-1 rounded-full bg-primary" />
        <span>{length(@children)} children</span>
        <Core.icon
          name="chevron-down"
          class="h-3 w-3 transition-transform group-open/family:rotate-180"
        />
      </summary>

      <div class={[
        "absolute left-0 top-full z-30 mt-1.5",
        "min-w-[280px] max-w-[420px] rounded-md border border-border",
        "bg-popover/95 shadow-lg backdrop-blur-sm",
        "p-1.5"
      ]}>
        <div class="px-2 py-1 font-mono text-[9px] uppercase tracking-widest text-muted-foreground">
          Child workflows
        </div>
        <ul class="flex flex-col gap-0.5">
          <li :for={child <- @children}>
            <.link
              navigate={DPath.workflow_tab(@base_path, child.id, :flow)}
              class={[
                "flex items-center gap-2 px-2 py-1.5 rounded-sm",
                "hover:bg-accent transition-colors"
              ]}
            >
              <Core.status_pill status={child.status} />
              <div class="flex-1 min-w-0 flex flex-col leading-tight">
                <span class="font-mono text-[11px] truncate">
                  {child_label(child, @parent_step_lookup)}
                </span>
                <span class="font-mono text-[9px] text-muted-foreground truncate">
                  {short(child.id)}
                </span>
              </div>
              <Core.icon name="chevron-right" class="h-3 w-3 text-muted-foreground" />
            </.link>
          </li>
        </ul>
      </div>
    </details>
    """
  end

  defp child_label(child, parent_step_lookup) do
    case Map.get(parent_step_lookup, child.id) do
      nil -> "(no step)"
      step_name -> humanize_step_name(step_name)
    end
  end

  # Strip the qualified `parallel_<id>__` / `branch_<id>__<clause>__`
  # prefix the DSL synthesizes — leaves the user-defined name that the
  # popover label cares about. Mirrors the same logic used in graph_builder
  # for status overlay fallback.
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
end
