defmodule Durable.Migration.Base do
  @moduledoc """
  Base module for Durable internal migrations.

  This module provides the behaviour and DSL for creating Durable migrations.
  Each migration is a module that implements `version/0`, `up/1`, and `down/1`.

  ## Usage

      defmodule Durable.Migration.Migrations.V20260103120000AddCompensation do
        use Durable.Migration.Base

        @impl true
        def version, do: 20_260_103_120_000

        @impl true
        def up(prefix) do
          alter table(:workflow_executions, prefix: prefix) do
            add(:compensation_data, :jsonb)
          end
        end

        @impl true
        def down(prefix) do
          alter table(:workflow_executions, prefix: prefix) do
            remove(:compensation_data)
          end
        end
      end

  The `prefix` argument is the PostgreSQL schema name (default: "durable").
  All Ecto.Migration functions are available (create, alter, drop, execute, etc.).
  """

  @doc """
  Returns the migration version as a positive integer.

  Version format: YYYYMMDDHHmmss (14 digits)
  Example: 20260103120000
  """
  @callback version() :: pos_integer()

  @doc """
  Runs the migration up (apply changes).

  The prefix argument is the PostgreSQL schema name.
  """
  @callback up(prefix :: String.t()) :: :ok

  @doc """
  Runs the migration down (rollback changes).

  The prefix argument is the PostgreSQL schema name.
  """
  @callback down(prefix :: String.t()) :: :ok

  defmacro __using__(_opts) do
    quote do
      @behaviour Durable.Migration.Base
      use Ecto.Migration

      @impl true
      def up(_prefix), do: :ok

      @impl true
      def down(_prefix), do: :ok

      defoverridable up: 1, down: 1
    end
  end
end
