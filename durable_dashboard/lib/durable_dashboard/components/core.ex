defmodule DurableDashboard.Components.Core do
  @moduledoc """
  Stateless function components used across the dashboard.

  Stateful pieces (filter bars, paginated tables, palettes) live as
  `Phoenix.LiveComponent` modules elsewhere. Anything visual, parameterized,
  and stateless lives here so it can be composed without `:id` ceremony.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # ============================================================================
  # Icon
  # ============================================================================

  @doc """
  Renders an inline SVG icon. The available set is curated; add new icons by
  extending the `~H` clause below with a new pattern match.

  ## Examples

      <.icon name="check" />
      <.icon name="x-mark" class="size-5" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"
  attr :rest, :global

  def icon(%{name: "check"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M16.704 4.153a.75.75 0 0 1 .143 1.052l-8 10.5a.75.75 0 0 1-1.127.075l-4.5-4.5a.75.75 0 0 1 1.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 0 1 1.05-.143Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "x-mark"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z" />
    </svg>
    """
  end

  def icon(%{name: "chevron-right"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M7.21 14.77a.75.75 0 0 1 .02-1.06L11.168 10 7.23 6.29a.75.75 0 1 1 1.04-1.08l4.5 4.25a.75.75 0 0 1 0 1.08l-4.5 4.25a.75.75 0 0 1-1.06-.02Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "chevron-left"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M12.79 5.23a.75.75 0 0 1-.02 1.06L8.832 10l3.938 3.71a.75.75 0 1 1-1.04 1.08l-4.5-4.25a.75.75 0 0 1 0-1.08l4.5-4.25a.75.75 0 0 1 1.06.02Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "chevron-down"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M5.22 8.22a.75.75 0 0 1 1.06 0L10 11.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 9.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "search"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M9 3.5a5.5 5.5 0 1 0 3.405 9.83l3.382 3.382a.75.75 0 0 0 1.06-1.06l-3.382-3.382A5.5 5.5 0 0 0 9 3.5ZM5 9a4 4 0 1 1 8 0 4 4 0 0 1-8 0Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "exclamation-triangle"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495ZM10 5a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 10 5Zm0 9a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "information-circle"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0Zm-7-4a1 1 0 1 1-2 0 1 1 0 0 1 2 0ZM9 9a.75.75 0 0 0 0 1.5h.253a.25.25 0 0 1 .244.304l-.459 2.066A1.75 1.75 0 0 0 10.747 15H11a.75.75 0 0 0 0-1.5h-.253a.25.25 0 0 1-.244-.304l.459-2.066A1.75 1.75 0 0 0 9.253 9H9Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "home"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path d="M9.293 2.293a1 1 0 0 1 1.414 0l7 7A1 1 0 0 1 17 11h-1v6a1 1 0 0 1-1 1h-2a1 1 0 0 1-1-1v-3a1 1 0 0 0-1-1H9a1 1 0 0 0-1 1v3a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-6H3a1 1 0 0 1-.707-1.707l7-7Z" />
    </svg>
    """
  end

  def icon(%{name: "queue"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M2 4.75A.75.75 0 0 1 2.75 4h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 4.75ZM2 10a.75.75 0 0 1 .75-.75h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 10Zm0 5.25a.75.75 0 0 1 .75-.75h14.5a.75.75 0 0 1 0 1.5H2.75a.75.75 0 0 1-.75-.75Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "clock"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm.75-13a.75.75 0 0 0-1.5 0v5c0 .414.336.75.75.75h4a.75.75 0 0 0 0-1.5h-3.25V5Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "calendar"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M5.75 2a.75.75 0 0 1 .75.75V4h7V2.75a.75.75 0 0 1 1.5 0V4h.25A2.75 2.75 0 0 1 18 6.75v8.5A2.75 2.75 0 0 1 15.25 18H4.75A2.75 2.75 0 0 1 2 15.25v-8.5A2.75 2.75 0 0 1 4.75 4H5V2.75A.75.75 0 0 1 5.75 2Zm-1 5.5c-.69 0-1.25.56-1.25 1.25v6.5c0 .69.56 1.25 1.25 1.25h10.5c.69 0 1.25-.56 1.25-1.25v-6.5c0-.69-.56-1.25-1.25-1.25H4.75Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "inbox"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path d="M4.5 2.75a.75.75 0 0 0-.75.75v6h2.585a1.5 1.5 0 0 1 1.06.44l1.93 1.93a1.5 1.5 0 0 0 1.06.44h.83a1.5 1.5 0 0 0 1.06-.44l1.93-1.93a1.5 1.5 0 0 1 1.06-.44h2.585v-6a.75.75 0 0 0-.75-.75H4.5Z" />
      <path d="M3.75 11h2.585a.5.5 0 0 1 .353.146l1.93 1.93a2.5 2.5 0 0 0 1.768.732h.828a2.5 2.5 0 0 0 1.768-.732l1.93-1.93a.5.5 0 0 1 .353-.146h2.585a.75.75 0 0 1 0 1.5h-2.585a2 2 0 0 0-1.414.586l-1.93 1.93a4 4 0 0 1-2.829 1.172H10.207a4 4 0 0 1-2.829-1.172l-1.93-1.93A2 2 0 0 0 4.034 12.5H3.75a.75.75 0 0 1 0-1.5Z" />
    </svg>
    """
  end

  def icon(%{name: "settings"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M7.84 1.804A1 1 0 0 1 8.82 1h2.36a1 1 0 0 1 .98.804l.331 1.652a6.993 6.993 0 0 1 1.929 1.115l1.598-.54a1 1 0 0 1 1.186.447l1.18 2.044a1 1 0 0 1-.205 1.251l-1.267 1.113a7.047 7.047 0 0 1 0 2.228l1.267 1.113a1 1 0 0 1 .206 1.25l-1.18 2.045a1 1 0 0 1-1.187.447l-1.598-.54a6.993 6.993 0 0 1-1.929 1.115l-.33 1.652a1 1 0 0 1-.98.804H8.82a1 1 0 0 1-.98-.804l-.331-1.652a6.993 6.993 0 0 1-1.929-1.115l-1.598.54a1 1 0 0 1-1.186-.447l-1.18-2.044a1 1 0 0 1 .205-1.251l1.267-1.114a7.05 7.05 0 0 1 0-2.227L1.821 7.773a1 1 0 0 1-.206-1.25l1.18-2.045a1 1 0 0 1 1.187-.447l1.598.54A6.992 6.992 0 0 1 7.51 3.456l.33-1.652ZM10 13a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "ellipsis-horizontal"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path d="M3 10a1.5 1.5 0 1 1 3 0 1.5 1.5 0 0 1-3 0ZM8.5 10a1.5 1.5 0 1 1 3 0 1.5 1.5 0 0 1-3 0ZM15.5 8.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3Z" />
    </svg>
    """
  end

  def icon(%{name: "arrow-path"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M15.312 11.424a5.5 5.5 0 0 1-9.201 2.466l-.312-.311h2.433a.75.75 0 0 0 0-1.5H3.989a.75.75 0 0 0-.75.75v4.242a.75.75 0 0 0 1.5 0v-2.43l.31.31a7 7 0 0 0 11.712-3.138.75.75 0 0 0-1.449-.39ZM3.144 6.39a5.5 5.5 0 0 1 9.201-2.466l.314.31H10.23a.75.75 0 0 0 0 1.5h4.243a.75.75 0 0 0 .75-.75V.74a.75.75 0 0 0-1.5 0v2.43l-.31-.31A7 7 0 0 0 1.7 6.002a.75.75 0 1 0 1.448.388Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "play"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M2 10a8 8 0 1 1 16 0 8 8 0 0 1-16 0Zm6.39-2.908a.75.75 0 0 1 .766.027l3.5 2.25a.75.75 0 0 1 0 1.262l-3.5 2.25A.75.75 0 0 1 8 12.25v-4.5a.75.75 0 0 1 .39-.658Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "pause"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M2 10a8 8 0 1 1 16 0 8 8 0 0 1-16 0Zm5-2.25A.75.75 0 0 1 7.75 7h.5a.75.75 0 0 1 .75.75v4.5a.75.75 0 0 1-.75.75h-.5A.75.75 0 0 1 7 12.25v-4.5Zm4.25-.75a.75.75 0 0 0-.75.75v4.5c0 .414.336.75.75.75h.5a.75.75 0 0 0 .75-.75v-4.5a.75.75 0 0 0-.75-.75h-.5Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "moon"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path fill-rule="evenodd" d="M7.455 2.004a.75.75 0 0 1 .26.77 7 7 0 0 0 9.81 7.51.75.75 0 0 1 1.075.953 8.5 8.5 0 1 1-11.527-9.831.75.75 0 0 1 .382.598Z" clip-rule="evenodd" />
    </svg>
    """
  end

  def icon(%{name: "sun"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class={@class} {@rest}>
      <path d="M10 2a.75.75 0 0 1 .75.75v1.5a.75.75 0 0 1-1.5 0v-1.5A.75.75 0 0 1 10 2ZM10 15a.75.75 0 0 1 .75.75v1.5a.75.75 0 0 1-1.5 0v-1.5A.75.75 0 0 1 10 15ZM10 7a3 3 0 1 0 0 6 3 3 0 0 0 0-6ZM15.657 5.404a.75.75 0 1 0-1.06-1.06l-1.061 1.06a.75.75 0 0 0 1.06 1.06l1.06-1.06ZM6.464 14.596a.75.75 0 1 0-1.06-1.06l-1.06 1.06a.75.75 0 0 0 1.06 1.06l1.06-1.06ZM18 10a.75.75 0 0 1-.75.75h-1.5a.75.75 0 0 1 0-1.5h1.5A.75.75 0 0 1 18 10ZM5 10a.75.75 0 0 1-.75.75h-1.5a.75.75 0 0 1 0-1.5h1.5A.75.75 0 0 1 5 10ZM14.596 15.657a.75.75 0 0 0 1.06-1.06l-1.06-1.061a.75.75 0 1 0-1.06 1.06l1.06 1.06ZM5.404 6.464a.75.75 0 0 0 1.06-1.06l-1.06-1.06a.75.75 0 1 0-1.061 1.06l1.06 1.06Z" />
    </svg>
    """
  end

  def icon(%{name: "command"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" class={@class} {@rest}>
      <path d="M6 6V4.5a2 2 0 1 1 2 2H6Zm0 0v8m0 0v1.5a2 2 0 1 1-2-2H6Zm0 0h8m0 0v1.5a2 2 0 1 0 2-2h-2Zm0 0V6m0 0V4.5a2 2 0 1 0-2 2h2Z" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
    """
  end

  def icon(%{name: name} = assigns) when is_binary(name) do
    # Unknown icon — render a placeholder square so it's visible during dev.
    ~H"""
    <span
      role="img"
      aria-label={"icon: " <> @name}
      title={"missing icon: " <> @name}
      class={[@class, "inline-block bg-destructive/30 rounded-sm"]}
      {@rest}
    >
    </span>
    """
  end

  # ============================================================================
  # Button
  # ============================================================================

  @doc """
  A button with kind variants.

  ## Examples

      <.button>Default</.button>
      <.button kind="primary" type="submit">Save</.button>
      <.button kind="ghost" phx-click="cancel">Cancel</.button>
  """
  attr :kind, :string,
    default: "secondary",
    values: ~w(primary secondary ghost destructive link)

  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :type, :string, default: "button"
  attr :class, :string, default: nil

  attr :rest, :global,
    include: ~w(disabled form name value phx-click phx-target phx-value-id href patch navigate)

  slot :inner_block, required: true

  def button(assigns) do
    if navigation_attrs?(assigns.rest) do
      ~H"""
      <.link class={[button_class(@kind, @size), @class]} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button type={@type} class={[button_class(@kind, @size), @class]} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp navigation_attrs?(rest) when is_map(rest) do
    Map.has_key?(rest, :href) or Map.has_key?(rest, :patch) or Map.has_key?(rest, :navigate)
  end

  defp navigation_attrs?(_), do: false

  defp button_class(kind, size) do
    base =
      "inline-flex items-center justify-center gap-1.5 rounded-md font-medium " <>
        "transition-colors disabled:opacity-50 disabled:pointer-events-none " <>
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 " <>
        "focus-visible:ring-offset-background"

    size_class =
      case size do
        "sm" -> " h-7 px-2.5 text-xs"
        "md" -> " h-8 px-3 text-[13px]"
        "lg" -> " h-10 px-4 text-sm"
      end

    kind_class =
      case kind do
        "primary" ->
          " bg-primary text-primary-foreground hover:bg-primary/90"

        "secondary" ->
          " bg-secondary text-secondary-foreground border border-border hover:bg-accent"

        "ghost" ->
          " text-foreground hover:bg-accent hover:text-accent-foreground"

        "destructive" ->
          " bg-destructive text-destructive-foreground hover:bg-destructive/90"

        "link" ->
          " text-primary underline-offset-4 hover:underline"
      end

    base <> size_class <> kind_class
  end

  # ============================================================================
  # Icon button — square, icon-only
  # ============================================================================

  @doc """
  A square button containing only an icon. For toolbar-style controls
  (theme toggle, pagination chevrons, sheet-close, table actions).

  Variants: `default` (bordered card surface) | `ghost` (no border, hover
  bg only). Sizes: `sm` (28h) | `md` (32h).

  See `DESIGN.md` §5 (component primitives) and §8 (density).

  ## Examples

      <.icon_button icon="x-mark" aria-label="Close" phx-click="close" />
      <.icon_button kind="ghost" size="sm" icon="chevron-right" aria-label="Next" />
  """
  attr :icon, :string, required: true
  attr :kind, :string, default: "default", values: ~w(default ghost)
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :type, :string, default: "button"
  attr :class, :string, default: nil

  attr :rest, :global,
    include: ~w(disabled form name value phx-click phx-target phx-value-id aria-label)

  def icon_button(assigns) do
    ~H"""
    <button type={@type} class={[icon_button_class(@kind, @size), @class]} {@rest}>
      <.icon name={@icon} class={icon_button_icon_class(@size)} />
    </button>
    """
  end

  defp icon_button_class(kind, size) do
    base =
      "inline-flex items-center justify-center rounded-md " <>
        "transition-colors disabled:opacity-40 disabled:pointer-events-none " <>
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"

    size_class =
      case size do
        "sm" -> " size-7"
        "md" -> " size-8"
      end

    kind_class =
      case kind do
        "default" ->
          " border border-border bg-card/40 text-muted-foreground " <>
            "hover:bg-accent hover:text-accent-foreground"

        "ghost" ->
          " text-muted-foreground hover:bg-accent hover:text-accent-foreground"
      end

    base <> size_class <> kind_class
  end

  defp icon_button_icon_class("sm"), do: "size-3.5"
  defp icon_button_icon_class("md"), do: "size-4"

  # ============================================================================
  # Keyboard hint
  # ============================================================================

  @doc """
  Renders a keyboard shortcut hint.

  ## Examples

      <.kbd>⌘K</.kbd>
      <.kbd>Esc</.kbd>
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def kbd(assigns) do
    ~H"""
    <kbd class={[
      "inline-flex items-center justify-center min-w-[20px] h-5 px-1.5",
      "rounded-sm border border-border bg-muted text-muted-foreground",
      "font-mono text-[10px] tracking-wide",
      @class
    ]}>
      {render_slot(@inner_block)}
    </kbd>
    """
  end

  # ============================================================================
  # Badge
  # ============================================================================

  @doc """
  A small label tag.

  ## Examples

      <.badge>default</.badge>
      <.badge kind="success">running</.badge>
  """
  attr :kind, :string,
    default: "default",
    values: ~w(default primary success warning destructive info muted)

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[badge_class(@kind), @class]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_class(kind) do
    base =
      "inline-flex items-center rounded-sm px-1.5 h-5 text-[10px] font-medium " <>
        "uppercase tracking-wider whitespace-nowrap"

    case kind do
      "default" -> base <> " bg-secondary text-secondary-foreground"
      "primary" -> base <> " bg-primary/15 text-primary"
      "success" -> base <> " bg-success/15 text-success"
      "warning" -> base <> " bg-warning/15 text-warning"
      "destructive" -> base <> " bg-destructive/15 text-destructive"
      "info" -> base <> " bg-info/15 text-info"
      "muted" -> base <> " bg-muted text-muted-foreground"
    end
  end

  # ============================================================================
  # Status pill
  # ============================================================================

  @doc """
  A status pill for workflow / step states. Uses semantic colors and an LED
  pulse for active states.

  ## Examples

      <.status_pill status={:running} />
      <.status_pill status="completed" />
  """
  attr :status, :any, required: true
  attr :class, :string, default: nil

  def status_pill(assigns) do
    {label, kind, dot} = status_meta(assigns.status)
    assigns = assign(assigns, label: label, kind: kind, dot: dot)

    ~H"""
    <span class={[status_pill_class(@kind), @class]}>
      <span :if={@dot != :none} class={status_dot_class(@kind, @dot)}></span>
      {@label}
    </span>
    """
  end

  defp status_meta(s) when is_atom(s), do: status_meta(Atom.to_string(s))

  defp status_meta(s) when is_binary(s) do
    case s do
      "pending" -> {"pending", "muted", :none}
      "running" -> {"running", "success", :pulse}
      "waiting" -> {"waiting", "warning", :solid}
      "completed" -> {"completed", "success", :solid}
      "failed" -> {"failed", "destructive", :none}
      "cancelled" -> {"cancelled", "muted", :none}
      "scheduled" -> {"scheduled", "info", :none}
      "compensating" -> {"compensating", "warning", :pulse}
      "timeout" -> {"timeout", "destructive", :none}
      other -> {other, "muted", :none}
    end
  end

  defp status_pill_class(kind) do
    base =
      "inline-flex items-center gap-1.5 rounded-sm px-2 h-6 text-[11px] " <>
        "font-medium whitespace-nowrap border"

    case kind do
      "muted" -> base <> " bg-muted/40 text-muted-foreground border-border"
      "success" -> base <> " bg-success/10 text-success border-success/20"
      "warning" -> base <> " bg-warning/10 text-warning border-warning/20"
      "destructive" -> base <> " bg-destructive/10 text-destructive border-destructive/20"
      "info" -> base <> " bg-info/10 text-info border-info/20"
    end
  end

  defp status_dot_class(kind, dot) do
    base = "inline-block size-1.5 rounded-full"

    color =
      case kind do
        "muted" -> " bg-muted-foreground"
        "success" -> " bg-success"
        "warning" -> " bg-warning"
        "destructive" -> " bg-destructive"
        "info" -> " bg-info"
      end

    case dot do
      :pulse -> base <> color <> " led-dot"
      :solid -> base <> color
      :none -> base
    end
  end

  # ============================================================================
  # Relative time
  # ============================================================================

  @doc """
  Renders a relative time like "2m ago" with a tooltip showing the absolute
  ISO timestamp.

  ## Examples

      <.relative_time at={execution.inserted_at} />
  """
  attr :at, :any, required: true
  attr :class, :string, default: nil

  def relative_time(assigns) do
    {label, full} = relative_time_label(assigns.at)
    assigns = assign(assigns, label: label, full: full)

    ~H"""
    <span class={["text-numeric text-xs", @class]} title={@full}>
      {@label}
    </span>
    """
  end

  defp relative_time_label(nil), do: {"—", "—"}

  defp relative_time_label(%DateTime{} = dt) do
    diff_s = DateTime.diff(DateTime.utc_now(), dt, :second)
    {humanize_diff(diff_s), DateTime.to_iso8601(dt)}
  end

  defp relative_time_label(%NaiveDateTime{} = dt) do
    case DateTime.from_naive(dt, "Etc/UTC") do
      {:ok, utc} -> relative_time_label(utc)
      _ -> {"—", "—"}
    end
  end

  defp relative_time_label(other), do: {to_string(other), to_string(other)}

  defp humanize_diff(s) when s < 5, do: "just now"
  defp humanize_diff(s) when s < 60, do: "#{s}s ago"
  defp humanize_diff(s) when s < 3600, do: "#{div(s, 60)}m ago"
  defp humanize_diff(s) when s < 86_400, do: "#{div(s, 3600)}h ago"
  defp humanize_diff(s) when s < 604_800, do: "#{div(s, 86_400)}d ago"
  defp humanize_diff(s) when s < 2_592_000, do: "#{div(s, 604_800)}w ago"
  defp humanize_diff(s), do: "#{div(s, 2_592_000)}mo ago"

  # ============================================================================
  # Empty state
  # ============================================================================

  @doc """
  Centered empty-state placeholder.

  ## Examples

      <.empty_state title="No workflows yet" />
      <.empty_state title="No results" description="Try adjusting filters." />
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :icon, :string, default: nil
  attr :class, :string, default: nil
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "flex flex-col items-center justify-center text-center py-16 px-6",
      "text-muted-foreground",
      @class
    ]}>
      <.icon :if={@icon} name={@icon} class="size-8 mb-3 opacity-60" />
      <h3 class="text-sm font-medium text-foreground">{@title}</h3>
      <p :if={@description} class="text-xs mt-1 max-w-sm">{@description}</p>
      <div :if={@action != []} class="mt-4">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  # ============================================================================
  # Card
  # ============================================================================

  @doc """
  A surface container with optional header.

  ## Examples

      <.card>
        Content
      </.card>

      <.card>
        <:title>Section</:title>
        <:action><.button kind="ghost">View all</.button></:action>
        Content
      </.card>
  """
  attr :class, :string, default: nil
  attr :padding, :string, default: "md", values: ~w(none sm md lg)
  attr :rest, :global

  slot :title
  slot :action
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section
      class={[
        "rounded-md border border-border bg-card text-card-foreground",
        @class
      ]}
      {@rest}
    >
      <header
        :if={@title != [] or @action != []}
        class="flex items-center justify-between gap-3 px-4 h-12 border-b border-border"
      >
        <h3 :if={@title != []} class="text-sm font-medium text-heading">
          {render_slot(@title)}
        </h3>
        <div :if={@action != []} class="flex items-center gap-2">
          {render_slot(@action)}
        </div>
      </header>
      <div class={card_padding_class(@padding)}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp card_padding_class("none"), do: ""
  defp card_padding_class("sm"), do: "p-3"
  defp card_padding_class("md"), do: "p-4"
  defp card_padding_class("lg"), do: "p-6"

  # ============================================================================
  # Heading
  # ============================================================================

  @doc """
  Page / section heading.

  ## Examples

      <.heading level={1}>Workflows</.heading>
      <.heading level={2} subtitle="Past 24 hours">Activity</.heading>
  """
  attr :level, :integer, default: 1, values: [1, 2, 3]
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def heading(assigns) do
    ~H"""
    <div class={["flex flex-col gap-0.5", @class]}>
      <.heading_tag level={@level}>
        {render_slot(@inner_block)}
      </.heading_tag>
      <p :if={@subtitle} class="text-xs text-muted-foreground">{@subtitle}</p>
    </div>
    """
  end

  attr :level, :integer, required: true
  slot :inner_block, required: true

  defp heading_tag(%{level: 1} = assigns) do
    ~H"""
    <h1 class="text-heading text-[22px]">{render_slot(@inner_block)}</h1>
    """
  end

  defp heading_tag(%{level: 2} = assigns) do
    ~H"""
    <h2 class="text-heading text-[18px]">{render_slot(@inner_block)}</h2>
    """
  end

  defp heading_tag(%{level: 3} = assigns) do
    ~H"""
    <h3 class="text-heading text-sm">{render_slot(@inner_block)}</h3>
    """
  end

  # ============================================================================
  # Code (inline + block)
  # ============================================================================

  @doc """
  Renders code in monospace. Use for IDs, JSON snippets, durations.

  ## Examples

      <.code>{exec.id}</.code>
      <.code class="text-info">{job.queue}</.code>
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def code(assigns) do
    ~H"""
    <code class={[
      "font-mono text-numeric text-xs text-foreground/90",
      "px-1 py-0.5 rounded-sm bg-muted/40 border border-border",
      @class
    ]}>
      {render_slot(@inner_block)}
    </code>
    """
  end

  # ============================================================================
  # Skeleton — loading placeholder
  # ============================================================================

  @doc """
  Animated placeholder. Use to indicate that a section is loading without
  collapsing layout. Composable: stack multiple skeletons of varying widths
  to mimic the shape of the eventual content.

  ## Examples

      <.skeleton class="h-4 w-32" />
      <.skeleton class="h-8 w-full" />
      <.skeleton variant="circle" class="size-8" />
  """
  attr :class, :string, default: "h-4 w-full"
  attr :variant, :string, default: "default", values: ~w(default circle pill)
  attr :rest, :global

  def skeleton(assigns) do
    ~H"""
    <div
      aria-hidden="true"
      class={[
        "animate-pulse bg-muted/60",
        skeleton_shape(@variant),
        @class
      ]}
      {@rest}
    >
    </div>
    """
  end

  defp skeleton_shape("circle"), do: "rounded-full"
  defp skeleton_shape("pill"), do: "rounded-full"
  defp skeleton_shape(_), do: "rounded-md"

  # ============================================================================
  # Error state — distinct from empty_state for "something failed" surfaces
  # ============================================================================

  @doc """
  Centered error placeholder with semantic destructive styling and an
  optional retry action. Distinct from `<.empty_state>` so operators
  immediately see the difference between "nothing here yet" and
  "something is broken."

  ## Examples

      <.error_state title="Failed to load workflows" />
      <.error_state title="..." description="..." reason="DBConnection timeout">
        <:action><.button kind="ghost" phx-click="retry">Retry</.button></:action>
      </.error_state>
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :reason, :string, default: nil
  attr :class, :string, default: nil
  slot :action

  def error_state(assigns) do
    ~H"""
    <div
      role="alert"
      class={[
        "flex flex-col items-center justify-center text-center py-16 px-6",
        @class
      ]}
    >
      <div class="size-10 mb-3 rounded-full bg-destructive/10 border border-destructive/20 flex items-center justify-center">
        <.icon name="exclamation-triangle" class="size-5 text-destructive" />
      </div>
      <h3 class="text-sm font-medium text-foreground">{@title}</h3>
      <p :if={@description} class="text-xs mt-1 max-w-sm text-muted-foreground">
        {@description}
      </p>
      <p :if={@reason} class="text-[11px] font-mono mt-2 max-w-md text-destructive/80 break-words">
        {@reason}
      </p>
      <div :if={@action != []} class="mt-4">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  # ============================================================================
  # Misc helpers re-exported
  # ============================================================================

  @doc """
  `JS.dispatch/2` shim convenience used by the theme toggle.
  """
  def toggle_theme do
    JS.dispatch("durable:toggle-theme", to: "html")
  end
end
