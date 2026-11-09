defmodule Durable.Keys do
  @moduledoc false
  # Workflow keys: at most one run per workflow and key holds the key
  # (`holds_key`), enforced by a unique index on that flag alone. Status is not
  # part of the index, so no status change can raise a unique error or free a
  # key. A key changes hands only here:
  #
  #   * a start whose key is held by a closed run that `reuse:` lets go, or
  #     by an open run it replaces (`on_duplicate: :cancel_existing`)
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
  @waiting_target {:unsafe_fragment,
                   "(workflow_module, workflow_name, key) " <>
                     "WHERE runs_after_id IS NOT NULL AND status = 'pending'"}
  @rounds 3
  @max_input_bytes 16_384
  @modes [:use_existing, :error, :cancel_existing, :run_again]
  # Statuses `Durable.cancel/2` can cancel; a compensating run finishes its rollback.
  @cancellable [:pending, :running, :waiting]

  @doc false
  # Option checks that are programmer errors, so they raise.
  @spec validate_start_opts!(keyword()) :: :ok
  def validate_start_opts!(opts) do
    for opt <- [:reuse, :debounce], Keyword.has_key?(opts, opt) do
      raise ArgumentError,
            "#{opt}: is set on the workflow (`workflow \"name\", #{opt}: ...`), " <>
              "not per call, so every producer gets the same answer for a key"
    end

    with {:ok, value} <- Keyword.fetch(opts, :on_duplicate), do: validate_on_duplicate!(value)

    for {opt, value} <- Keyword.take(opts, [:key, :queue, :tags]), Repo.bad_text?(value) do
      raise ArgumentError, "#{opt}: can't be stored: #{inspect(value)}"
    end

    :ok
  end

  @doc false
  @spec validate_on_duplicate!(term()) :: term()
  def validate_on_duplicate!(value) when value in @modes, do: value

  def validate_on_duplicate!({:send_event, name} = value) when is_binary(name) and name != "",
    do: value

  def validate_on_duplicate!(value) do
    raise ArgumentError,
          "invalid on_duplicate: #{inspect(value)}; expected :use_existing, :error, " <>
            ":cancel_existing, :run_again or {:send_event, event_name}"
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
  # The workflow's `debounce:` as `%{period: ms, timeout: ms | nil}`, or nil.
  @spec debounce(Durable.Definition.Workflow.t()) :: map() | nil
  def debounce(%{opts: opts}) do
    case Map.get(opts, :debounce) do
      nil -> nil
      list when is_list(list) -> debounce_opts(list)
      other -> raise ArgumentError, "invalid debounce: #{inspect(other)}"
    end
  end

  defp debounce_opts(list) do
    period = Keyword.get(list, :period)
    timeout = Keyword.get(list, :timeout)

    valid? =
      Keyword.keys(list) -- [:period, :timeout] == [] and positive?(period) and
        (is_nil(timeout) or positive?(timeout))

    if valid?,
      do: %{period: period, timeout: timeout},
      else:
        raise(ArgumentError,
          message:
            "invalid debounce: #{inspect(list)}; expected [period: ms] or [period: ms, timeout: ms]"
        )
  end

  defp positive?(n), do: is_integer(n) and n > 0

  @doc false
  # When a keyed start of this workflow is due: `period` from now for a
  # debounced workflow (or the caller's later `scheduled_at`).
  @spec debounced_start(Durable.Definition.Workflow.t(), DateTime.t() | nil) :: DateTime.t() | nil
  def debounced_start(workflow_def, scheduled_at) do
    case debounce(workflow_def) do
      nil ->
        scheduled_at

      %{period: period} ->
        latest(scheduled_at, DateTime.add(DateTime.utc_now(), period, :millisecond))
    end
  end

  defp latest(nil, at), do: at
  defp latest(a, b), do: if(DateTime.after?(a, b), do: a, else: b)

  @doc false
  # Inserts a keyed run. Returns `{:ok, run}` for a new run (it holds the key),
  # `{:duplicate, holder_id, :use_existing | :error}` when the start didn't
  # create one, or `{:error, reason}`.
  @spec insert(Config.t(), Ecto.Changeset.t(), Durable.Definition.Workflow.t(), keyword()) ::
          {:ok, WorkflowExecution.t()} | {:duplicate, String.t(), atom()} | {:error, term()}
  def insert(_config, %Ecto.Changeset{valid?: false} = changeset, _workflow_def, _opts),
    do: {:error, changeset}

  def insert(config, changeset, workflow_def, opts) do
    mode =
      validate_on_duplicate!(
        Keyword.get(opts, :on_duplicate) ||
          Map.get(workflow_def.opts, :on_duplicate, :use_existing)
      )

    if mode == :run_again and reuse(workflow_def) == :never do
      raise ArgumentError,
            "on_duplicate: :run_again can't run again with reuse: :never: " <>
              "no run after the first may take the key"
    end

    ctx = %{
      config: config,
      entry: entry(changeset),
      reuse: reuse(workflow_def),
      mode: mode,
      debounce: debounce(workflow_def),
      workflow_def: workflow_def
    }

    # One transaction so a release (or a replaced holder's cancel) and the
    # insert that follows land together. Nothing in here raises on a taken
    # key, and nothing rolls back, so a caller's own transaction stays usable.
    {:ok, result} =
      Repo.transaction(config, fn ->
        lock_key(config, ctx.entry)
        claim(ctx, @rounds, nil)
      end)

    finish(ctx, result)
  end

  # Every change to who holds a key takes this first, so a start and a run taking
  # over from a finished holder can't lock the same rows in opposite orders.
  defp lock_key(config, %{workflow_module: module, workflow_name: name, key: key}) do
    {:ok, _} =
      Repo.query(config, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "durable_key:#{module}:#{name}:#{key}"
      ])

    :ok
  end

  defp claim(_ctx, 0, _moved), do: :contended

  defp claim(ctx, rounds, moved) do
    case Repo.insert_all(ctx.config, WorkflowExecution, [ctx.entry],
           on_conflict: :nothing,
           conflict_target: @holder_target,
           returning: true
         ) do
      {1, [run]} -> {:inserted, run, moved}
      {0, _} -> taken(ctx, rounds, moved)
    end
  end

  # The insert hit a holder.
  defp taken(ctx, rounds, moved) do
    case holder(ctx.config, ctx.entry) do
      # Gone between the insert and the read (pruned, released): try again.
      nil -> claim(ctx, rounds - 1, moved)
      holder -> take(ctx, holder, rounds, moved)
    end
  end

  defp take(ctx, holder, rounds, moved) do
    cond do
      # A finished holder `reuse:` lets go hands its key over.
      holder.status in WorkflowExecution.reusable_statuses(ctx.reuse) ->
        moved =
          if release_closed(ctx.config, holder, ctx.reuse), do: {:released, holder}, else: moved

        claim(ctx, rounds - 1, moved)

      # A debounced run that hasn't started takes the newer input and waits again.
      debouncing?(ctx, holder) ->
        if debounce_holder(ctx, holder),
          do: {:debounced, holder},
          else: claim(ctx, rounds - 1, moved)

      ctx.mode == :run_again ->
        run_again(ctx, holder, rounds, moved)

      ctx.mode == :cancel_existing and holder.status in @cancellable ->
        replace(ctx, holder, rounds, moved)

      true ->
        {:taken, holder}
    end
  end

  # run_again: a holder that hasn't started takes the newer input; one that's
  # going gets a run waiting behind it. A closed holder `reuse:` keeps is taken.
  defp run_again(ctx, holder, rounds, moved) do
    cond do
      unstarted?(holder) ->
        if refresh_unstarted(ctx, holder),
          do: {:refreshed, holder},
          else: claim(ctx, rounds - 1, moved)

      holder.status in WorkflowExecution.open_statuses() ->
        run_after(ctx, holder, rounds, moved)

      true ->
        {:taken, holder}
    end
  end

  defp replace(ctx, holder, rounds, moved) do
    case cancel_holder(ctx, holder) do
      nil -> claim(ctx, rounds - 1, moved)
      cancelled -> claim(ctx, rounds - 1, {:replaced, holder, cancelled})
    end
  end

  defp debouncing?(%{debounce: nil}, _holder), do: false
  defp debouncing?(_ctx, holder), do: unstarted?(holder)

  # Never claimed. A parked retry or snooze is :pending and unlocked too, but
  # it has started.
  defp unstarted?(holder),
    do: holder.status == :pending and is_nil(holder.locked_by) and is_nil(holder.started_at)

  defp unstarted_holder(holder_id) do
    from(w in WorkflowExecution,
      where:
        w.id == ^holder_id and w.holds_key and w.status == :pending and is_nil(w.locked_by) and
          is_nil(w.started_at)
    )
  end

  defp refresh_unstarted(ctx, holder) do
    {count, _} =
      Repo.update_all(ctx.config, unstarted_holder(holder.id),
        set: [input: ctx.entry.input, updated_at: DateTime.utc_now()]
      )

    count == 1
  end

  # on_duplicate: :run_again with the holder going: one run waits for it to
  # end (runs_after_id, which the claim query honours), without the key. A
  # later start gives that run the newest input. Its deadline counts from when
  # it takes the key.
  defp run_after(ctx, holder, rounds, moved) do
    waiting =
      %{ctx.entry | holds_key: false, deadline_at: nil} |> Map.put(:runs_after_id, holder.id)

    case Repo.insert_all(ctx.config, WorkflowExecution, [waiting],
           on_conflict: :nothing,
           conflict_target: @waiting_target,
           returning: true
         ) do
      {1, [run]} ->
        {:waiting, run, holder}

      {0, _} ->
        case refresh_waiting(ctx) do
          nil -> claim(ctx, rounds - 1, moved)
          id -> {:waiting_refreshed, id, holder}
        end
    end
  end

  defp refresh_waiting(%{config: config, entry: entry}) do
    {_, ids} =
      Repo.update_all(
        config,
        from(w in WorkflowExecution,
          where:
            w.workflow_module == ^entry.workflow_module and
              w.workflow_name == ^entry.workflow_name and w.key == ^entry.key and
              not is_nil(w.runs_after_id) and w.status == :pending and is_nil(w.locked_by),
          select: w.id
        ),
        set: [input: entry.input, updated_at: DateTime.utc_now()]
      )

    List.first(ids)
  end

  # Gives the newer input to a debounced run that hasn't been claimed, and
  # pushes its start back by `period`, but not past `timeout` after the first
  # start. Matches no row once a worker claimed it.
  defp debounce_holder(%{debounce: %{period: period, timeout: timeout}} = ctx, holder) do
    now = DateTime.utc_now()
    at = DateTime.add(now, period, :millisecond)

    at =
      if timeout,
        do: earliest(at, DateTime.add(holder.inserted_at, timeout, :millisecond)),
        else: at

    {count, _} =
      Repo.update_all(
        ctx.config,
        unstarted_holder(holder.id),
        set: [
          input: ctx.entry.input,
          scheduled_at: at,
          deadline_at: Executor.deadline(ctx.workflow_def, at),
          updated_at: now
        ]
      )

    count == 1
  end

  defp earliest(a, b), do: if(DateTime.before?(a, b), do: a, else: b)

  # `on_duplicate: :cancel_existing`: cancel the open holder and take its key
  # in one UPDATE, under any `reuse:`. Like `Durable.cancel/2`, a step in
  # flight finishes but its result is dropped; compensations don't run.
  defp cancel_holder(ctx, holder) do
    now = DateTime.utc_now()

    error = %{
      type: "cancelled",
      message:
        "Replaced by run #{String.slice(ctx.entry.id, 0, 8)} (on_duplicate: :cancel_existing)",
      replaced_by: ctx.entry.id
    }

    case Repo.update_all(
           ctx.config,
           from(w in WorkflowExecution,
             where: w.id == ^holder.id and w.holds_key and w.status in ^@cancellable,
             select: w
           ),
           set: [
             status: :cancelled,
             error: error,
             completed_at: now,
             updated_at: now,
             locked_by: nil,
             locked_at: nil,
             lock_token: nil,
             holds_key: false
           ]
         ) do
      {1, [cancelled]} -> cancelled
      {0, _} -> nil
    end
  end

  defp finish(ctx, result) do
    case result do
      {:inserted, run, nil} ->
        {:ok, run}

      {:inserted, run, {:released, from}} ->
        record_handoff(ctx, run, from, %{})
        {:ok, run}

      {:inserted, run, {:replaced, from, cancelled}} ->
        record_duplicate(ctx, from, :cancel_existing)
        record_handoff(ctx, run, from, %{replaced: true})
        Executor.after_cancel(ctx.config, cancelled)
        {:ok, run}

      {:debounced, holder} ->
        record_duplicate(ctx, holder, :debounced)
        {:duplicate, holder.id, :use_existing}

      {:refreshed, holder} ->
        record_duplicate(ctx, holder, :run_again)
        {:duplicate, holder.id, :use_existing}

      {:waiting, run, holder} ->
        record_duplicate(ctx, holder, :run_again, %{runs_after: run.id})
        {:ok, run}

      {:waiting_refreshed, id, holder} ->
        record_duplicate(ctx, holder, :run_again, %{runs_after: id})
        {:duplicate, id, :use_existing}

      {:taken, holder} ->
        answer(ctx, holder)

      :contended ->
        {:error, :key_contended}
    end
  end

  # The holder keeps the key; what the caller gets back.
  defp answer(%{mode: mode} = ctx, holder) when mode in [:use_existing, :error] do
    record_duplicate(ctx, holder, mode)
    {:duplicate, holder.id, mode}
  end

  defp answer(%{mode: {:send_event, name}} = ctx, holder) do
    if holder.status in WorkflowExecution.open_statuses() and
         Durable.Wait.send_event(holder.id, name, ctx.entry.input,
           buffer: true,
           durable: ctx.config.name
         ) == :ok do
      record_duplicate(ctx, holder, :send_event, %{event: name})
      {:duplicate, holder.id, :use_existing}
    else
      record_duplicate(ctx, holder, :error)
      {:duplicate, holder.id, :error}
    end
  end

  # :cancel_existing with a holder it can't cancel: compensating, or finished
  # and kept by `reuse:`.
  defp answer(ctx, holder) do
    record_duplicate(ctx, holder, :error)
    {:duplicate, holder.id, :error}
  end

  defp entry(changeset) do
    now = DateTime.utc_now()

    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.take(WorkflowExecution.__schema__(:fields))
    |> Map.merge(%{id: Ecto.UUID.generate(), holds_key: true, inserted_at: now, updated_at: now})
  end

  defp holder(config, %{workflow_module: module, workflow_name: name, key: key}) do
    Repo.one(
      config,
      from(w in WorkflowExecution,
        where:
          w.workflow_module == ^module and w.workflow_name == ^name and w.key == ^key and
            w.holds_key,
        select:
          struct(w, [
            :id,
            :status,
            :input,
            :key,
            :workflow_module,
            :workflow_name,
            :locked_by,
            :started_at,
            :inserted_at
          ])
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
  # A run that waited behind a holder (run_again) was claimed, so that holder
  # has ended. It takes the key by the start rules: `{:ok, run}` holding it,
  # `{:behind, holder_id}` when another run took the key meanwhile (wait for
  # that one instead), or `{:kept, holder_id}` when `reuse:` keeps it.
  @spec take_waiting(Config.t(), WorkflowExecution.t(), Durable.Definition.Workflow.t()) ::
          {:ok, WorkflowExecution.t()} | {:behind, String.t()} | {:kept, String.t()}
  def take_waiting(config, run, workflow_def) do
    {:ok, result} =
      Repo.transaction(config, fn ->
        lock_key(config, run)
        do_take_waiting(config, run, workflow_def, @rounds)
      end)

    case result do
      {:ok, taken, from} ->
        if from, do: record(config, "key_handed_off", taken, %{key: run.key, from: from.id})
        {:ok, taken}

      other ->
        other
    end
  end

  defp do_take_waiting(config, run, _workflow_def, 0),
    do: {:behind, holder_id(config, run) || run.runs_after_id}

  defp do_take_waiting(config, run, workflow_def, rounds) do
    reuse = reuse(workflow_def)

    case holder(config, run) do
      nil ->
        hold(config, run, workflow_def, nil, rounds)

      holder ->
        cond do
          holder.status in WorkflowExecution.open_statuses() ->
            {:behind, holder.id}

          holder.status not in WorkflowExecution.reusable_statuses(reuse) ->
            {:kept, holder.id}

          release_closed(config, holder, reuse) ->
            hold(config, run, workflow_def, holder, rounds)

          true ->
            do_take_waiting(config, run, workflow_def, rounds - 1)
        end
    end
  end

  defp hold(config, run, workflow_def, from, rounds) do
    run
    |> Ecto.Changeset.change(
      holds_key: true,
      runs_after_id: nil,
      deadline_at: Executor.deadline(workflow_def, DateTime.utc_now())
    )
    |> Ecto.Changeset.unique_constraint(:key, name: :workflow_executions_key_holder_index)
    |> Repo.update(config, mode: :savepoint)
    |> case do
      {:ok, taken} -> {:ok, taken, from}
      {:error, _} -> do_take_waiting(config, run, workflow_def, rounds - 1)
    end
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

    case Repo.id?(workflow_id) && Repo.get(config, WorkflowExecution, workflow_id) do
      not_a_run when not_a_run in [nil, false] ->
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

  defp record_duplicate(ctx, holder, outcome, extra \\ %{}) do
    %{config: config, entry: entry} = ctx
    input = Executor.sanitize_for_json(entry.input || %{})
    changed = json(input) != json(holder.input || %{})

    details =
      %{
        key: entry.key,
        workflow: entry.workflow_name,
        outcome: outcome,
        holder_status: holder.status,
        input_changed: changed
      }
      |> Map.merge(extra)
      |> put_input(changed, input)

    record(config, "key_duplicate", holder, details)

    :telemetry.execute([:durable, :key, :duplicate], %{count: 1}, %{
      durable: config.name,
      workflow: entry.workflow_name,
      key: entry.key,
      holder_id: holder.id,
      outcome: outcome,
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

  defp record_handoff(ctx, run, from, extra) do
    record(
      ctx.config,
      "key_handed_off",
      run,
      Map.merge(%{from: from.id, from_status: from.status, reuse: ctx.reuse}, extra)
    )

    :telemetry.execute([:durable, :key, :handoff], %{count: 1}, %{
      durable: ctx.config.name,
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
