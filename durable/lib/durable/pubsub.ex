defmodule Durable.PubSub do
  @moduledoc """
  Thin wrapper around `Phoenix.PubSub` for broadcasting Durable lifecycle events.

  This module is a no-op when `phoenix_pubsub` is not loaded, so it is safe to
  call from executor code regardless of whether a dashboard or external consumer
  is subscribed.

  ## Topics

  Broadcasts go to three topic families, scoped per Durable instance (the
  instance name is taken from the config):

    * `"durable:<instance>:workflows"` — every workflow lifecycle event
    * `"durable:<instance>:workflow:<id>"` — events for one specific workflow
    * `"durable:<instance>:schedules"` — schedule CRUD events
    * `"durable:<instance>:inputs"` — pending input lifecycle events

  ## Event shape

  Every broadcast is the tuple `{:durable_event, kind, payload}` where `kind` is
  one of the atoms enumerated in `t:kind/0` and `payload` is a map with fields
  relevant to the event. See the individual `broadcast_*` helpers for specifics.

  ## Enabling

  Add `{:phoenix_pubsub, "~> 2.1"}` to your dependencies and either:

    * Pass `pubsub: MyApp.PubSub` in the Durable supervision-tree args to reuse
      a PubSub started by the host app, or
    * Pass nothing — Durable will start its own `Phoenix.PubSub` named
      `Durable.<instance>.PubSub`.

  When neither a dependency nor a `:pubsub` option is present, all broadcasts
  silently no-op and subscribers simply never receive messages.
  """

  alias Durable.Config

  @type kind ::
          :workflow_started
          | :workflow_resumed
          | :workflow_waiting
          | :workflow_completed
          | :workflow_failed
          | :workflow_cancelled
          | :step_started
          | :step_completed
          | :step_failed
          | :step_waiting
          | :input_requested
          | :input_provided
          | :schedule_toggled
          | :schedule_triggered

  @type payload :: map()

  @doc """
  Returns the PubSub server name for a Durable instance.

  Returns `nil` when the instance has no PubSub configured.
  """
  @spec server(Config.t()) :: module() | nil
  def server(%Config{pubsub: nil}), do: nil
  def server(%Config{pubsub: name}) when is_atom(name), do: name

  @doc """
  Returns the PubSub server name for an instance by name (convenience).
  """
  @spec server_for(atom()) :: module() | nil
  def server_for(instance_name) do
    case Config.get_safe(instance_name) do
      nil -> nil
      config -> server(config)
    end
  end

  @doc """
  Returns the default `Phoenix.PubSub` child spec name for a Durable instance.

  Used by the supervisor to start an owned PubSub when the caller did not
  provide one.
  """
  @spec default_name(atom()) :: atom()
  def default_name(instance_name) do
    Module.concat([instance_name, PubSub])
  end

  @doc """
  Returns the topic string for all workflow events on this instance.
  """
  @spec workflows_topic(Config.t()) :: String.t()
  def workflows_topic(%Config{name: name}), do: "durable:#{name}:workflows"

  @doc """
  Returns the topic string for one specific workflow's events.
  """
  @spec workflow_topic(Config.t(), String.t()) :: String.t()
  def workflow_topic(%Config{name: name}, workflow_id) do
    "durable:#{name}:workflow:#{workflow_id}"
  end

  @doc """
  Returns the topic string for schedule events on this instance.
  """
  @spec schedules_topic(Config.t()) :: String.t()
  def schedules_topic(%Config{name: name}), do: "durable:#{name}:schedules"

  @doc """
  Returns the topic string for pending-input events on this instance.
  """
  @spec inputs_topic(Config.t()) :: String.t()
  def inputs_topic(%Config{name: name}), do: "durable:#{name}:inputs"

  @doc """
  Subscribes the calling process to a topic.

  Returns `:ok` if PubSub is configured, `{:error, :no_pubsub}` otherwise.
  """
  @spec subscribe(Config.t(), String.t()) :: :ok | {:error, :no_pubsub}
  def subscribe(%Config{} = config, topic) do
    with server when not is_nil(server) <- server(config),
         true <- pubsub_loaded?() do
      Phoenix.PubSub.subscribe(server, topic)
    else
      _ -> {:error, :no_pubsub}
    end
  end

  @doc """
  Unsubscribes the calling process from a topic.
  """
  @spec unsubscribe(Config.t(), String.t()) :: :ok
  def unsubscribe(%Config{} = config, topic) do
    with server when not is_nil(server) <- server(config),
         true <- pubsub_loaded?() do
      Phoenix.PubSub.unsubscribe(server, topic)
    else
      _ -> :ok
    end
  end

  @doc """
  Broadcasts a workflow lifecycle event.

  Sends to both the global workflows topic and the per-workflow topic.
  """
  @spec broadcast_workflow(Config.t(), kind(), payload()) :: :ok
  def broadcast_workflow(%Config{} = config, kind, %{id: workflow_id} = payload) do
    msg = {:durable_event, kind, payload}
    broadcast(config, workflows_topic(config), msg)
    broadcast(config, workflow_topic(config, workflow_id), msg)
  end

  @doc """
  Broadcasts a step lifecycle event.

  Sent only to the per-workflow topic (step events would overwhelm the global
  topic and aren't generally interesting at that level).
  """
  @spec broadcast_step(Config.t(), kind(), payload()) :: :ok
  def broadcast_step(%Config{} = config, kind, %{workflow_id: workflow_id} = payload) do
    msg = {:durable_event, kind, payload}
    broadcast(config, workflow_topic(config, workflow_id), msg)
  end

  @doc """
  Broadcasts a pending-input lifecycle event.

  Sent to both the inputs topic and the per-workflow topic.
  """
  @spec broadcast_input(Config.t(), kind(), payload()) :: :ok
  def broadcast_input(%Config{} = config, kind, %{workflow_id: workflow_id} = payload) do
    msg = {:durable_event, kind, payload}
    broadcast(config, inputs_topic(config), msg)
    broadcast(config, workflow_topic(config, workflow_id), msg)
  end

  @doc """
  Broadcasts a schedule event.
  """
  @spec broadcast_schedule(Config.t(), kind(), payload()) :: :ok
  def broadcast_schedule(%Config{} = config, kind, payload) do
    msg = {:durable_event, kind, payload}
    broadcast(config, schedules_topic(config), msg)
  end

  defp broadcast(%Config{} = config, topic, msg) do
    with server when not is_nil(server) <- server(config),
         true <- pubsub_loaded?() do
      Phoenix.PubSub.broadcast(server, topic, msg)
    else
      _ -> :ok
    end
  end

  defp pubsub_loaded?, do: Code.ensure_loaded?(Phoenix.PubSub)
end
