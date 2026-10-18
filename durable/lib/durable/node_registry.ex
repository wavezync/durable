defmodule Durable.NodeRegistry do
  @moduledoc """
  Keeps this instance's row in `durable.nodes` fresh, so operators can see
  which nodes are alive and which queues each runs.

  A node heartbeats every #{div(10_000, 1_000)} s and removes its row on a
  clean shutdown; `list/1` reports a node as `:missing` once its heartbeat is
  #{div(30_000, 1_000)} s old. Rows unseen for a day are deleted.

  On boot it also checks the database schema: a library upgrade whose
  migrations haven't run is logged as an error naming the missing version.
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias Durable.Config
  alias Durable.Repo
  alias Durable.Storage.Schemas.Node
  alias Durable.Storage.Schemas.WorkflowExecution

  @interval 10_000
  @missing_after_ms 30_000
  @forget_after_s 86_400

  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :config))

  @doc """
  Lists known nodes, newest heartbeat first, each with a `:status` of
  `:alive` or `:missing` and `:running`, the number of runs it holds a lock on.
  """
  @spec list(Config.t()) :: [map()]
  def list(%Config{} = config) do
    cutoff = DateTime.add(DateTime.utc_now(), -@missing_after_ms, :millisecond)

    running =
      config
      |> Repo.all(
        from(w in WorkflowExecution,
          where: w.status == :running and not is_nil(w.locked_by),
          group_by: w.locked_by,
          select: {w.locked_by, count(w.id)}
        )
      )
      |> Map.new()

    config
    |> Repo.all(from(n in Node, order_by: [desc: n.heartbeat_at]))
    |> Enum.map(fn node ->
      node
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> Map.merge(%{
        status: if(DateTime.before?(node.heartbeat_at, cutoff), do: :missing, else: :alive),
        running: Map.get(running, node.id, 0)
      })
    end)
  end

  @impl true
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)
    {:ok, %{config: config, started_at: DateTime.utc_now()}, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    check_schema(state.config)
    {:noreply, beat(state)}
  end

  @impl true
  def handle_info(:beat, state), do: {:noreply, beat(state)}

  @impl true
  def terminate(_reason, %{config: config}) do
    safely(fn -> Repo.delete_all(config, from(n in Node, where: n.id == ^config.node_id)) end)
  end

  defp beat(%{config: config} = state) do
    now = DateTime.utc_now()

    node = %Node{
      id: config.node_id,
      queues:
        if(config.queue_enabled, do: Enum.map(Map.keys(config.queues), &to_string/1), else: []),
      version: Application.spec(:durable, :vsn) |> to_string(),
      started_at: state.started_at,
      heartbeat_at: now
    }

    safely(fn ->
      Repo.insert(node, config,
        on_conflict: {:replace, [:queues, :version, :heartbeat_at]},
        conflict_target: :id
      )

      forgotten = DateTime.add(now, -@forget_after_s, :second)
      Repo.delete_all(config, from(n in Node, where: n.heartbeat_at < ^forgotten))
    end)

    Process.send_after(self(), :beat, @interval)
    state
  end

  defp check_schema(config) do
    safely(fn ->
      applied = Durable.Migration.migrated_version(config.repo, prefix: config.prefix)
      latest = Durable.Migration.current_version()

      if applied < latest do
        Logger.error(
          "[Durable] database schema #{inspect(config.prefix)} is at migration #{applied}, " <>
            "but this version of Durable needs #{latest}. Run `mix durable.gen.upgrade` " <>
            "and migrate — until then runs will fail to start or save."
        )
      end
    end)
  end

  # The registry is advisory; a database blip must never crash Durable's
  # supervision tree, so failures here are logged and retried next beat.
  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.debug("[Durable] node registry: #{Exception.message(e)}")
  end
end
