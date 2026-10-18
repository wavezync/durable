defmodule DurableDashboard.InboxBadge do
  @moduledoc """
  Keeps `:inbox_count` — inputs waiting on a person — on every dashboard
  page, for the sidebar's Inbox badge. Counted on mount, then again whenever
  an input is requested or answered (the inputs PubSub topic).

  The hook consumes those messages, so pages that don't handle them never see
  them. A page that wants them too assigns `wants_input_events: true` in its
  mount and they're passed on — rather than subscribing a second time.
  """

  import Ecto.Query

  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.PendingInput

  @kinds [:input_requested, :input_provided]

  @doc false
  def on_mount(:default, _params, session, socket) do
    config = Durable.Config.get_safe(session["config"].durable)

    if config && Phoenix.LiveView.connected?(socket),
      do: DurablePubSub.subscribe(config, DurablePubSub.inputs_topic(config))

    socket =
      socket
      |> Phoenix.Component.assign(inbox_count: count(config))
      |> Phoenix.LiveView.attach_hook(:inbox_badge, :handle_info, &recount(&1, &2, config))

    {:cont, socket}
  end

  @doc false
  def recount({:durable_event, kind, _payload}, socket, config) when kind in @kinds do
    socket = Phoenix.Component.assign(socket, inbox_count: count(config))
    if socket.assigns[:wants_input_events], do: {:cont, socket}, else: {:halt, socket}
  end

  def recount(_message, socket, _config), do: {:cont, socket}

  defp count(nil), do: 0

  defp count(config),
    do:
      Durable.Repo.one(
        config,
        from(p in PendingInput, where: p.status == :pending, select: count(p.id))
      )
end
