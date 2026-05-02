defmodule DurableDashboard.Components.Command.CommandPalette do
  @moduledoc """
  ⌘K command palette. Mounted once in the app layout — always present,
  hidden when closed. The JS hook (`assets/src/v2/hooks/command_palette.ts`)
  bridges keypresses to LC events.

  ## Events

  - `palette:open` — open the palette and focus the input
  - `palette:close` — close (Esc, click overlay, click X)
  - `palette:search` `%{"value" => q}` — phx-change on the input
  - `palette:move` `%{"dir" => "up" | "down"}` — keyboard nav
  - `palette:activate` — Enter key → live-navigate to the selected result

  ## Items

  Phase 5 v0 ships only the static route set. Live workflow search will
  land alongside the workflow stub adapter in a follow-up.
  """

  use Phoenix.LiveComponent

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Path, as: DPath

  @impl true
  def mount(socket) do
    {:ok, assign(socket, open?: false, query: "", selected_index: 0, items: [])}
  end

  @impl true
  def update(assigns, socket) do
    items = items_for(assigns[:base_path])
    filtered = filter_items(items, socket.assigns.query)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(items: items, results: filtered)
     |> clamp_selection()}
  end

  @impl true
  def handle_event("palette:open", _, socket) do
    {:noreply,
     socket
     |> assign(open?: true, query: "", selected_index: 0)
     |> assign(results: socket.assigns.items)}
  end

  def handle_event("palette:close", _, socket) do
    {:noreply, assign(socket, open?: false, query: "", selected_index: 0)}
  end

  def handle_event("palette:search", %{"value" => q}, socket) do
    filtered = filter_items(socket.assigns.items, q)

    {:noreply,
     socket
     |> assign(query: q, results: filtered, selected_index: 0)}
  end

  def handle_event("palette:move", %{"dir" => dir}, socket) do
    delta = if dir == "up", do: -1, else: 1
    count = length(socket.assigns.results)

    new_index =
      if count == 0 do
        0
      else
        rem(socket.assigns.selected_index + delta + count, count)
      end

    {:noreply, assign(socket, selected_index: new_index)}
  end

  def handle_event("palette:activate", _, socket) do
    case Enum.at(socket.assigns.results, socket.assigns.selected_index) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply,
         socket
         |> assign(open?: false, query: "")
         |> push_navigate(to: item.href)}
    end
  end

  def handle_event("palette:select", %{"index" => idx}, socket) do
    {:noreply, assign(socket, selected_index: String.to_integer(idx))}
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="CommandPalette"
      data-open={to_string(@open?)}
      class={["fixed inset-0 z-50", if(@open?, do: "block", else: "hidden")]}
    >
      <%!-- Backdrop click target — invisible-by-design click region, not a
            visual button. Stays as raw <button> for the a11y semantics
            without inheriting `Core.button`'s sizing/border. --%>
      <button
        type="button"
        aria-label="Close palette"
        class="absolute inset-0 bg-background/70 backdrop-blur-sm"
        phx-click="palette:close"
        phx-target={@myself}
      >
      </button>

      <div
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        class={[
          "relative mx-auto mt-[15vh] w-full max-w-xl",
          "rounded-md border border-border bg-popover text-popover-foreground",
          "shadow-2xl overflow-hidden"
        ]}
      >
        <div class="flex items-center gap-2 px-3 h-12 border-b border-border">
          <Core.icon name="search" class="size-4 text-muted-foreground shrink-0" />
          <form phx-change="palette:search" phx-target={@myself} class="flex-1">
            <input
              type="text"
              name="value"
              value={@query}
              placeholder="Search routes…"
              autocomplete="off"
              data-palette-input
              class={[
                "w-full h-8 bg-transparent border-none outline-none text-sm",
                "text-foreground placeholder:text-muted-foreground"
              ]}
            />
          </form>
          <Core.kbd>Esc</Core.kbd>
        </div>

        <div class="max-h-[50vh] overflow-auto thin-scroll" id={@id <> "-results"}>
          <%= if @results == [] do %>
            <div class="px-4 py-10 text-center text-[13px] text-muted-foreground">
              No matches for <span class="font-mono">"{@query}"</span>
            </div>
          <% else %>
            <ul role="listbox" class="py-1">
              <li
                :for={{item, idx} <- Enum.with_index(@results)}
                role="option"
                aria-selected={idx == @selected_index}
                phx-click="palette:activate"
                phx-target={@myself}
                phx-value-index={idx}
                phx-mouseenter={
                  Phoenix.LiveView.JS.push("palette:select",
                    target: @myself,
                    value: %{index: idx}
                  )
                }
                class={[
                  "flex items-center gap-3 px-3 h-9 cursor-pointer text-[13px]",
                  if idx == @selected_index do
                    "bg-accent text-accent-foreground"
                  else
                    "text-foreground hover:bg-accent/40"
                  end
                ]}
              >
                <Core.icon name={item.icon} class="size-4 text-muted-foreground" />
                <span class="flex-1 font-medium">{item.label}</span>
                <span class="text-[11px] text-muted-foreground">{item.kind}</span>
              </li>
            </ul>
          <% end %>
        </div>

        <div class="flex items-center justify-between px-3 h-9 border-t border-border text-[11px] text-muted-foreground">
          <div class="flex items-center gap-3">
            <span class="flex items-center gap-1">
              <Core.kbd>↑</Core.kbd><Core.kbd>↓</Core.kbd> navigate
            </span>
            <span class="flex items-center gap-1">
              <Core.kbd>↵</Core.kbd> open
            </span>
          </div>
          <div class="flex items-center gap-1">
            <Core.kbd>⌘</Core.kbd><Core.kbd>K</Core.kbd>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Items + filtering
  # ============================================================================

  defp items_for(nil), do: items_for("")

  defp items_for(base_path) do
    [
      %{kind: "Page", label: "Overview", icon: "home", href: DPath.overview(base_path)},
      %{kind: "Page", label: "Workflows", icon: "queue", href: DPath.workflows(base_path)},
      %{kind: "Page", label: "Pending inputs", icon: "inbox", href: DPath.inputs(base_path)},
      %{kind: "Page", label: "Schedules", icon: "calendar", href: DPath.schedules(base_path)},
      %{kind: "Page", label: "Settings", icon: "settings", href: DPath.settings(base_path)}
    ]
  end

  defp filter_items(items, ""), do: items
  defp filter_items(items, nil), do: items

  defp filter_items(items, query) do
    needle = String.downcase(query)

    items
    |> Enum.filter(fn item ->
      String.contains?(String.downcase(item.label), needle) or
        String.contains?(String.downcase(item.kind), needle)
    end)
  end

  defp clamp_selection(socket) do
    count = length(socket.assigns[:results] || [])

    cond do
      count == 0 -> assign(socket, selected_index: 0)
      socket.assigns.selected_index >= count -> assign(socket, selected_index: count - 1)
      socket.assigns.selected_index < 0 -> assign(socket, selected_index: 0)
      true -> socket
    end
  end
end
