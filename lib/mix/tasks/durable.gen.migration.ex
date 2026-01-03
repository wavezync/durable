defmodule Mix.Tasks.Durable.Gen.Migration do
  @shortdoc "Generates a new Durable migration"

  @moduledoc """
  Generates a new Durable internal migration.

  This is for Durable library developers only, not end users.

      $ mix durable.gen.migration add_compensation_tracking

  The generated migration will be created at:

      lib/durable/migration/migrations/v{timestamp}_{name}.ex

  ## Examples

      $ mix durable.gen.migration add_workflow_metadata
      $ mix durable.gen.migration add_retry_count

  After generating a migration, you must:

  1. Implement the `up/1` and `down/1` callbacks
  2. Add the migration module to `@migrations` in `lib/durable/migration/migrator.ex`
  """

  use Mix.Task

  import Mix.Generator

  @impl true
  def run(args) do
    case args do
      [name | _] ->
        generate_migration(name)

      [] ->
        Mix.raise("Expected migration name, e.g. mix durable.gen.migration add_new_field")
    end
  end

  defp generate_migration(name) do
    # Validate name
    unless valid_name?(name) do
      Mix.raise(
        "Migration name must be lowercase with underscores, e.g. add_new_field, not #{name}"
      )
    end

    # Generate timestamp
    timestamp = generate_timestamp()
    version = String.to_integer(timestamp)

    # Build paths and names
    module_name = camelize(name)
    filename = "v#{timestamp}_#{name}.ex"
    migrations_dir = Path.join(["lib", "durable", "migration", "migrations"])
    filepath = Path.join(migrations_dir, filename)

    # Ensure directory exists
    File.mkdir_p!(migrations_dir)

    # Generate the migration file
    assigns = [
      version: version,
      module_name: module_name,
      timestamp: timestamp
    ]

    create_file(filepath, migration_template(assigns))

    Mix.shell().info("""

    Remember to add this migration to the @migrations list in:

        lib/durable/migration/migrator.ex

    Add:

        Durable.Migration.Migrations.V#{timestamp}#{module_name}

    """)
  end

  defp valid_name?(name) do
    name =~ ~r/^[a-z][a-z0-9_]*$/
  end

  defp generate_timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    "#{year}" <>
      String.pad_leading("#{month}", 2, "0") <>
      String.pad_leading("#{day}", 2, "0") <>
      String.pad_leading("#{hour}", 2, "0") <>
      String.pad_leading("#{minute}", 2, "0") <>
      String.pad_leading("#{second}", 2, "0")
  end

  defp camelize(name) do
    name
    |> String.split("_")
    |> Enum.map_join(&String.capitalize/1)
  end

  defp migration_template(assigns) do
    version = Keyword.fetch!(assigns, :version)
    module_name = Keyword.fetch!(assigns, :module_name)
    timestamp = Keyword.fetch!(assigns, :timestamp)

    """
    defmodule Durable.Migration.Migrations.V#{timestamp}#{module_name} do
      @moduledoc false
      use Durable.Migration.Base

      @impl true
      def version, do: #{format_version(version)}

      @impl true
      def up(prefix) do
        # Add your migration here
        # Example:
        # alter table(:workflow_executions, prefix: prefix) do
        #   add(:new_field, :string)
        # end
        :ok
      end

      @impl true
      def down(prefix) do
        # Add your rollback here
        # Example:
        # alter table(:workflow_executions, prefix: prefix) do
        #   remove(:new_field)
        # end
        :ok
      end
    end
    """
  end

  defp format_version(version) when is_integer(version) do
    # Format with underscores for readability: 20_260_103_000_000
    version
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join("_", &Enum.join/1)
  end
end
