defmodule Durable.Storage.Schemas.ScheduledWorkflow do
  @moduledoc """
  Ecto schema for scheduled workflow records.

  Scheduled workflows represent cron-based recurring workflow executions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Crontab.CronExpression.Parser, as: CronParser

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          workflow_module: String.t(),
          workflow_name: String.t(),
          cron_expression: String.t(),
          timezone: String.t(),
          input: map(),
          queue: String.t(),
          enabled: boolean(),
          last_run_at: DateTime.t() | nil,
          next_run_at: DateTime.t() | nil,
          last_error: String.t() | nil,
          last_error_at: DateTime.t() | nil,
          consecutive_failures: integer(),
          auto_disabled_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "durable"
  schema "scheduled_workflows" do
    field(:name, :string)
    field(:workflow_module, :string)
    field(:workflow_name, :string)
    field(:cron_expression, :string)
    field(:timezone, :string, default: "UTC")
    field(:input, :map, default: %{})
    field(:queue, :string, default: "default")
    field(:enabled, :boolean, default: true)
    field(:last_run_at, :utc_datetime_usec)
    field(:next_run_at, :utc_datetime_usec)
    # Bug L-1 — scheduler resilience tracking
    field(:last_error, :string)
    field(:last_error_at, :utc_datetime_usec)
    field(:consecutive_failures, :integer, default: 0)
    field(:auto_disabled_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:name, :workflow_module, :workflow_name, :cron_expression]
  @optional_fields [
    :timezone,
    :input,
    :queue,
    :enabled,
    :last_run_at,
    :next_run_at,
    :last_error,
    :last_error_at,
    :consecutive_failures,
    :auto_disabled_at
  ]

  @doc """
  Creates a changeset for inserting or updating a scheduled workflow.
  """
  def changeset(scheduled_workflow, attrs) do
    scheduled_workflow
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
    |> validate_cron_expression()
  end

  @doc """
  Creates a changeset for updating the last/next run times.
  """
  def run_changeset(scheduled_workflow, last_run_at, next_run_at) do
    scheduled_workflow
    |> cast(%{last_run_at: last_run_at, next_run_at: next_run_at}, [:last_run_at, :next_run_at])
  end

  @doc """
  Creates a changeset for enabling/disabling a scheduled workflow.
  """
  def enable_changeset(scheduled_workflow, enabled) do
    scheduled_workflow
    |> cast(%{enabled: enabled}, [:enabled])
  end

  @doc """
  Creates a changeset that records a failure to load / start the scheduled
  workflow. Increments `consecutive_failures` and stamps `last_error*`.
  When the failure count reaches `auto_disable_after`, the schedule is
  automatically disabled and `auto_disabled_at` is set so operators can
  tell why the schedule stopped firing.
  """
  def failure_changeset(scheduled_workflow, error_message, opts \\ []) do
    auto_disable_after = Keyword.get(opts, :auto_disable_after, 5)
    next_run_at = Keyword.get(opts, :next_run_at)
    now = DateTime.utc_now()
    new_count = (scheduled_workflow.consecutive_failures || 0) + 1
    auto_disable? = new_count >= auto_disable_after

    attrs = %{
      last_error: String.slice(to_string(error_message), 0, 1024),
      last_error_at: now,
      consecutive_failures: new_count,
      next_run_at: next_run_at
    }

    attrs =
      if auto_disable? do
        attrs
        |> Map.put(:enabled, false)
        |> Map.put(:auto_disabled_at, now)
      else
        attrs
      end

    cast(scheduled_workflow, attrs, [
      :last_error,
      :last_error_at,
      :consecutive_failures,
      :enabled,
      :auto_disabled_at,
      :next_run_at
    ])
  end

  @doc """
  Creates a changeset that records a successful trigger. Resets
  `consecutive_failures` to 0 and clears the last_error fields.
  """
  def success_changeset(scheduled_workflow, last_run_at, next_run_at) do
    cast(
      scheduled_workflow,
      %{
        last_run_at: last_run_at,
        next_run_at: next_run_at,
        last_error: nil,
        last_error_at: nil,
        consecutive_failures: 0
      },
      [
        :last_run_at,
        :next_run_at,
        :last_error,
        :last_error_at,
        :consecutive_failures
      ]
    )
  end

  @doc """
  Creates a changeset for upserting during registration.

  Updates cron, timezone, input, and queue, but preserves enabled status
  and run times for existing records.
  """
  def upsert_changeset(scheduled_workflow, attrs) do
    # Only update these fields during registration - preserve enabled, last_run_at, next_run_at
    upsert_fields = [
      :workflow_module,
      :workflow_name,
      :cron_expression,
      :timezone,
      :input,
      :queue
    ]

    scheduled_workflow
    |> cast(attrs, [:name | upsert_fields])
    |> validate_required(@required_fields)
    |> validate_cron_expression()
  end

  @doc """
  Creates a changeset for updating a schedule's configuration.
  """
  def update_changeset(scheduled_workflow, attrs) do
    update_fields = [:cron_expression, :timezone, :input, :queue, :enabled, :next_run_at]

    scheduled_workflow
    |> cast(attrs, update_fields)
    |> validate_cron_expression()
  end

  defp validate_cron_expression(changeset) do
    case get_change(changeset, :cron_expression) do
      nil ->
        changeset

      cron ->
        case CronParser.parse(cron) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :cron_expression, "is not a valid cron expression")
        end
    end
  end
end
