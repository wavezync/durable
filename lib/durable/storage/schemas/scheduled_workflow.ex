defmodule Durable.Storage.Schemas.ScheduledWorkflow do
  @moduledoc """
  Ecto schema for scheduled workflow records.

  Scheduled workflows represent cron-based recurring workflow executions.
  """

  use Ecto.Schema
  import Ecto.Changeset

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
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "scheduled_workflows" do
    field :name, :string
    field :workflow_module, :string
    field :workflow_name, :string
    field :cron_expression, :string
    field :timezone, :string, default: "UTC"
    field :input, :map, default: %{}
    field :queue, :string, default: "default"
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime_usec
    field :next_run_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:name, :workflow_module, :workflow_name, :cron_expression]
  @optional_fields [
    :timezone,
    :input,
    :queue,
    :enabled,
    :last_run_at,
    :next_run_at
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

  defp validate_cron_expression(changeset) do
    case get_change(changeset, :cron_expression) do
      nil ->
        changeset

      cron ->
        case Crontab.CronExpression.Parser.parse(cron) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :cron_expression, "is not a valid cron expression")
        end
    end
  end
end
