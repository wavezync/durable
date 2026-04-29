defmodule DurableDashboard.Components.Data.Pagination do
  @moduledoc """
  Stateless pagination control. Emits a `phx-click` event to a target with
  the new page number; the target (DataTable LiveComponent) decides how to
  apply it.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core

  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total, :integer, required: true
  attr :event, :string, default: "data_table:page"
  attr :target, :any, required: true
  attr :class, :string, default: nil

  def pagination(assigns) do
    last_page = max(1, ceil(assigns.total / assigns.per_page))
    from = (assigns.page - 1) * assigns.per_page + 1
    to = min(assigns.page * assigns.per_page, assigns.total)

    assigns =
      assign(assigns,
        last_page: last_page,
        from: from,
        to: to,
        prev_disabled?: assigns.page <= 1,
        next_disabled?: assigns.page >= last_page
      )

    ~H"""
    <div class={[
      "flex items-center justify-between px-4 h-10 border-t border-border",
      "text-xs text-muted-foreground",
      @class
    ]}>
      <div class="text-numeric">
        <%= if @total == 0 do %>
          0 results
        <% else %>
          <span class="text-foreground">{@from}</span>–<span class="text-foreground">{@to}</span>
          of <span class="text-foreground">{@total}</span>
        <% end %>
      </div>

      <div class="flex items-center gap-1">
        <Core.icon_button
          kind="ghost"
          size="sm"
          icon="chevron-left"
          aria-label="Previous page"
          phx-click={@event}
          phx-value-page={@page - 1}
          phx-target={@target}
          disabled={@prev_disabled?}
        />

        <span class="px-2 text-numeric text-xs text-foreground">
          {@page} / {@last_page}
        </span>

        <Core.icon_button
          kind="ghost"
          size="sm"
          icon="chevron-right"
          aria-label="Next page"
          phx-click={@event}
          phx-value-page={@page + 1}
          phx-target={@target}
          disabled={@next_disabled?}
        />
      </div>
    </div>
    """
  end
end
