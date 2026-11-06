defmodule Durable.Keys do
  @moduledoc false
  # Workflow keys: at most one run per workflow and key holds the key
  # (`holds_key`), enforced by a unique index on that flag alone. Status is not
  # part of the index, so no status change can raise a unique error or free a
  # key. A key changes hands only here:
  #
  #   * a start whose key is held by a closed run that `reuse:` lets go
  #     (`insert/4`),
  #   * a retry taking back the key it lost (`retake/3`),
  #   * an operator releasing it (`release/2`),
  #   * pruning, which deletes the holder.
  #
  # Releasing a holder is one UPDATE on its own row whose WHERE reads only that
  # row (`holds_key AND status = ANY(reusable)`). A retry reopening the same
  # row is also one UPDATE on it, so Postgres orders the two and whichever
  # commits second matches no row. Two inserts meet at the unique index.

  import Ecto.Query

  alias Durable.Activity
  alias Durable.Config
  alias Durable.Executor
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

  @holder_target {:unsafe_fragment, "(workflow_module, workflow_name, key) WHERE holds_key"}
  @rounds 3
  @max_input_bytes 16_384
  @on_duplicate [:use_existing, :error]

  @doc false
  # Option checks that are programmer errors, so they raise.
  @spec validate_start_opts!(keyword()) :: :ok
  def validate_start_opts!(opts) do
    if Keyword.has_key?(opts, :reuse) do
      raise ArgumentError,
            "reuse: is set on the workflow (`workflow \"name\", reuse: :never`), " <>
              "not per call, so every producer gets the same answer for a key"
    end

    case Keyword.fetch(opts, :on_duplicate) do
      {:ok, value} when value not in @on_duplicate ->
        raise ArgumentError,
              "invalid on_duplicate: #{inspect(value)}; expected one of #{inspect(@on_duplicate)}"

      _ ->
        :ok
    end
  end

  @doc false
  @spec reuse(Durable.Definition.Workflow.t()) :: atom()
  def reuse(%{opts: opts}) do
    policy = Map.get(opts, :reuse, :after_close)

    if policy in WorkflowExecution.reuse_policies(),
      do: policy,
      else: raise(ArgumentError, "invalid reuse: #{inspect(policy)}")
  end

  @doc false
  # Inserts a keyed run. Returns `{:ok, run}` for a new run (it holds the key),
  # `{:duplicate, holder_id, on_duplicate}` when the key is taken, or
  # `{:error, reason}`.
  @spec insert(Config.t(), Ecto.Changeset.t(), Durable.Definition.Workflow.t(), keyword()) ::
          {:ok, WorkflowExecution.t()} | {:duplicate, String.t(), atom()} | {:error, term()}
  def insert(_config, %Ecto.Changeset{valid?: false} = changeset, _workflow_def, _opts),
    do: {:error, changeset}

  def insert(config, changeset, workflow_def, opts) do
    on_duplicate =
      Keyword.get(opts, :on_duplicate) || Map.get(workflow_def.opts, :on_duplicate, :use_existing)

    if on_duplicate not in @on_duplicate,
      do: raise(ArgumentError, "invalid on_duplicate: #{inspect(on_duplicate)}")

    reuse = reuse(workflow_def)
    entry = entry(changeset)

    # One transaction so a release and the insert that follows land together.
    # Nothing in here raises on a taken key, and nothing rolls back, so a
    # caller's own transaction stays usable after a duplicate.
    {:ok, result} =
      Repo.transaction(config, fn -> claim(config, entry, reuse, @rounds, nil) end)

    case result do
      {:inserted, run, released} ->
        if released, do: record_handoff(config, run, released, reuse)
        {:ok, run}

      {:taken, holder} ->
        record_duplicate(config, entry, holder, on_duplicate)
        {:duplicate, holder.id, on_duplicate}

      :contended ->
        {:error, :key_contended}
    end
  end

  defp claim(_config, _entry, _reuse, 0, _released), do: :contended

  defp claim(config, entry, reuse, rounds, released) do
    row = %{entry | id: Ecto.UUID.generate()}

    case Repo.insert_all(config, WorkflowExecution, [row],
           on_conflict: :nothing,
           conflict_target: @holder_target,
           returning: true
         ) do
      {1, [run]} -> {:inserted, run, released}
      {0, _} -> taken(config, entry, reuse, rounds, released)
    end
  end

  # The insert hit a holder. Hand the key over if `reuse:` lets the holder go,
  # else the key is taken.
  defp taken(config, entry, reuse, rounds, released) do
    case holder(config, entry) do
      # Gone between the insert and the read (pruned, released): try again.
      nil ->
        claim(config, entry, reuse, rounds - 1, released)

      holder ->
        if holder.status in WorkflowExecution.reusable_statuses(reuse),
          do: claim(config, entry, reuse, rounds - 1, hand_over(config, holder, reuse, released)),
          else: {:taken, holder}
    end
  end

  defp hand_over(config, holder, reuse, released),
    do: if(release_closed(config, holder, reuse), do: holder, else: released)

  defp entry(changeset) do
    now = DateTime.utc_now()

    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.take(WorkflowExecution.__schema__(:fields))
    |> Map.merge(%{holds_key: true, inserted_at: now, updated_at: now})
  end

  defp holder(config, %{workflow_module: module, workflow_name: name, key: key}) do
    Repo.one(
      config,
      from(w in WorkflowExecution,
        where:
          w.workflow_module == ^module and w.workflow_name == ^name and w.key == ^key and
            w.holds_key,
        select: struct(w, [:id, :status, :input, :key, :workflow_module, :workflow_name])
      )
    )
  end

  # Releases a closed holder only if it's still closed, still holds the key,
  # and `reuse:` still lets it go.
  defp release_closed(config, holder, reuse) do
    statuses = WorkflowExecution.reusable_statuses(reuse)

    {count, _} =
      Repo.update_all(
        config,
        from(w in WorkflowExecution,
          where: w.id == ^holder.id and w.holds_key and w.status in ^statuses
        ),
        set: [holds_key: false, updated_at: DateTime.utc_now()]
      )

    count == 1
  end

  @doc false
  # A retry of a run that lost its key takes it back by the start rules.
  # Returns the extra fields for the reopening UPDATE (`[]` when nothing needs
  # to change, `[holds_key: true]` when it takes the key back) or
  # `{:error, {:key_taken, holder_id}}`.
  @spec retake(Config.t(), WorkflowExecution.t(), Durable.Definition.Workflow.t() | nil) ::
          {:ok, keyword()} | {:error, {:key_taken, String.t()}}
  def retake(_config, %WorkflowExecution{key: nil}, _workflow_def), do: {:ok, []}
  def retake(_config, %WorkflowExecution{holds_key: true}, _workflow_def), do: {:ok, []}

  def retake(config, %WorkflowExecution{} = run, workflow_def) do
    reuse = if workflow_def, do: reuse(workflow_def), else: :never
    do_retake(config, run, reuse, @rounds)
  end

  defp do_retake(config, run, _reuse, 0), do: {:error, {:key_taken, holder_id(config, run)}}

  defp do_retake(config, run, reuse, rounds) do
    case holder(config, run) do
      nil ->
        {:ok, [holds_key: true]}

      holder ->
        cond do
          holder.status not in WorkflowExecution.reusable_statuses(reuse) ->
            {:error, {:key_taken, holder.id}}

          release_closed(config, holder, reuse) ->
            record(config, "key_retaken", run, %{from: holder.id})
            {:ok, [holds_key: true]}

          true ->
            do_retake(config, run, reuse, rounds - 1)
        end
    end
  end

  defp holder_id(config, run) do
    case holder(config, run) do
      nil -> nil
      holder -> holder.id
    end
  end

  @doc false
  # The reopening UPDATE of a retry that takes its key back can still meet a
  # start that took the key in between; that's the one unique error left, and
  # it becomes `{:key_taken, id}`.
  @spec key_taken?(Ecto.Changeset.t()) :: boolean()
  def key_taken?(%Ecto.Changeset{errors: errors}),
    do: match?({_, [constraint: :unique, constraint_name: _]}, errors[:key])

  @doc false
  @spec key_taken_error(Config.t(), WorkflowExecution.t()) :: {:error, {:key_taken, term()}}
  def key_taken_error(config, run), do: {:error, {:key_taken, holder_id(config, run)}}

  @doc false
  @spec release(String.t(), keyword()) :: :ok | {:error, term()}
  def release(workflow_id, opts) do
    config = Config.get(Keyword.get(opts, :durable, Durable))

    case Repo.get(config, WorkflowExecution, workflow_id) do
      nil ->
        {:error, :not_found}

      %{holds_key: false} ->
        {:error, :no_key}

      run ->
        release_finished(config, run, Keyword.get(opts, :by))
    end
  end

  defp release_finished(config, run, by) do
    closed = WorkflowExecution.closed_statuses()

    case Repo.update_all(
           config,
           from(w in WorkflowExecution,
             where: w.id == ^run.id and w.holds_key and w.status in ^closed
           ),
           set: [holds_key: false, updated_at: DateTime.utc_now()]
         ) do
      {1, _} ->
        record(config, "key_released", run, if(by, do: %{by: to_string(by)}, else: %{}))

        :telemetry.execute([:durable, :key, :release], %{count: 1}, %{
          durable: config.name,
          workflow: run.workflow_name,
          key: run.key,
          workflow_id: run.id,
          by: by
        })

        :ok

      {0, _} ->
        release_refused(config, run.id)
    end
  end

  defp release_refused(config, id) do
    case Repo.get(config, WorkflowExecution, id) do
      nil -> {:error, :not_found}
      %{holds_key: false} -> {:error, :no_key}
      _open -> {:error, :not_finished}
    end
  end

  # --------------------------------------------------------------------------
  # Tracking

  defp record_duplicate(config, entry, holder, on_duplicate) do
    input = Executor.sanitize_for_json(entry.input || %{})
    changed = json(input) != json(holder.input || %{})

    details =
      %{
        key: entry.key,
        workflow: entry.workflow_name,
        outcome: on_duplicate,
        holder_status: holder.status,
        input_changed: changed
      }
      |> put_input(changed, input)

    record(config, "key_duplicate", holder, details)

    :telemetry.execute([:durable, :key, :duplicate], %{count: 1}, %{
      durable: config.name,
      workflow: entry.workflow_name,
      key: entry.key,
      holder_id: holder.id,
      outcome: on_duplicate,
      input_changed: changed
    })
  end

  defp put_input(details, false, _input), do: details

  defp put_input(details, true, input) do
    if byte_size(Jason.encode!(input)) <= @max_input_bytes,
      do: Map.put(details, :input, input),
      else: Map.put(details, :input_truncated, true)
  end

  # Compare as stored JSON, so atom and string keys compare equal.
  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp record_handoff(config, run, from, reuse) do
    record(config, "key_handed_off", run, %{
      from: from.id,
      from_status: from.status,
      reuse: reuse
    })

    :telemetry.execute([:durable, :key, :handoff], %{count: 1}, %{
      durable: config.name,
      workflow: run.workflow_name,
      key: run.key,
      from: from.id,
      to: run.id
    })
  end

  defp record(config, kind, run, details) do
    Activity.record(config, kind,
      workflow_id: run.id,
      details: Map.merge(%{key: run.key, workflow: run.workflow_name}, details)
    )
  end
end
