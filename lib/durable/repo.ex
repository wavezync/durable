defmodule Durable.Repo do
  @moduledoc """
  Wrapper for Ecto repo calls with centralized options.

  This module provides wrapper functions for common Ecto operations that
  automatically apply default options from the Durable configuration,
  such as the `log` option for controlling query logging.

  ## Usage

  Instead of calling the repo directly:

      repo = config.repo
      repo.all(query)

  Use the wrapper with the config:

      alias Durable.Repo
      Repo.all(config, query)

  This ensures consistent behavior across all Durable database operations.
  """

  alias Durable.Config
  alias Ecto.Adapters.SQL

  @doc """
  Returns the default options to apply to all Ecto operations.
  """
  @spec default_options(Config.t()) :: keyword()
  def default_options(%Config{} = config) do
    [log: config.log_level]
  end

  # ============================================================================
  # Query Operations
  # ============================================================================

  @doc """
  Fetches all entries from the data store matching the given query.
  """
  def all(%Config{} = config, queryable, opts \\ []) do
    config.repo.all(queryable, merge_opts(config, opts))
  end

  @doc """
  Fetches a single result from the query.
  """
  def one(%Config{} = config, queryable, opts \\ []) do
    config.repo.one(queryable, merge_opts(config, opts))
  end

  @doc """
  Fetches a single struct from the data store where the primary key matches the given id.
  """
  def get(%Config{} = config, schema, id, opts \\ []) do
    config.repo.get(schema, id, merge_opts(config, opts))
  end

  @doc """
  Fetches a single result from the query matching the given clauses.
  """
  def get_by(%Config{} = config, schema, clauses, opts \\ []) do
    config.repo.get_by(schema, clauses, merge_opts(config, opts))
  end

  @doc """
  Calculates the given aggregate over the given field.
  """
  def aggregate(%Config{} = config, queryable, aggregate, opts \\ []) do
    config.repo.aggregate(queryable, aggregate, merge_opts(config, opts))
  end

  # ============================================================================
  # Write Operations
  # Note: These have struct/changeset as first arg to support piping:
  #   changeset |> Repo.insert(config)
  #   changeset |> Repo.update(config)
  # ============================================================================

  @doc """
  Inserts a struct defined via `Ecto.Schema` or a changeset.

  Accepts struct/changeset as first arg to support piping.
  """
  def insert(struct_or_changeset, %Config{} = config, opts \\ []) do
    config.repo.insert(struct_or_changeset, merge_opts(config, opts))
  end

  @doc """
  Updates a changeset using its primary key.

  Accepts changeset as first arg to support piping.
  """
  def update(changeset, %Config{} = config, opts \\ []) do
    config.repo.update(changeset, merge_opts(config, opts))
  end

  @doc """
  Deletes a struct using its primary key.

  Accepts struct as first arg to support piping.
  """
  def delete(struct_or_changeset, %Config{} = config, opts \\ []) do
    config.repo.delete(struct_or_changeset, merge_opts(config, opts))
  end

  @doc """
  Inserts all entries into the repository.
  """
  def insert_all(%Config{} = config, schema_or_source, entries, opts \\ []) do
    config.repo.insert_all(schema_or_source, entries, merge_opts(config, opts))
  end

  @doc """
  Updates all entries matching the given query with the given values.
  """
  def update_all(%Config{} = config, queryable, updates, opts \\ []) do
    config.repo.update_all(queryable, updates, merge_opts(config, opts))
  end

  @doc """
  Deletes all entries matching the given query.
  """
  def delete_all(%Config{} = config, queryable, opts \\ []) do
    config.repo.delete_all(queryable, merge_opts(config, opts))
  end

  # ============================================================================
  # Raw SQL
  # ============================================================================

  @doc """
  Runs a custom SQL query on the given repo.
  """
  def query(%Config{} = config, sql, params \\ [], opts \\ []) do
    SQL.query(config.repo, sql, params, merge_opts(config, opts))
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp merge_opts(config, opts) do
    config
    |> default_options()
    |> Keyword.merge(opts)
  end
end
