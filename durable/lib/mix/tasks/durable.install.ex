if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Durable.Install do
    @shortdoc "Installs Durable into your project"

    @moduledoc """
    #{@shortdoc}

    This task will:
    1. Generate an Ecto migration to create the Durable tables
    2. Add Durable to your application's supervision tree

    ## Example

    ```sh
    mix durable.install
    ```

    ## Options

    * `--repo` or `-r` - The Ecto repo module to use. If not provided, will prompt or auto-select.
    """

    use Igniter.Mix.Task

    alias Igniter.Libs.Ecto, as: IgniterEcto
    alias Igniter.Project.Application, as: IgniterApplication

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :durable,
        example: "mix durable.install",
        schema: [repo: :string],
        aliases: [r: :repo],
        defaults: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options

      {igniter, repo} = select_repo(igniter, options)

      case repo do
        nil ->
          Igniter.add_issue(igniter, """
          No Ecto repo found in the project.

          Please ensure you have an Ecto repo configured before installing Durable.
          """)

        repo ->
          igniter
          |> generate_migration(repo)
          |> add_to_supervision_tree(repo)
          |> Igniter.add_notice("""
          Durable has been installed!

          Next steps:
          1. Run `mix ecto.migrate` to create the database tables
          2. (Optional) Configure additional queues in your supervision tree

          Configuration options:
            {Durable,
              repo: #{inspect(repo)},
              queues: %{default: [concurrency: 10]},
              queue_enabled: true,
              stale_lock_timeout: 300,
              heartbeat_interval: 30_000
            }
          """)
      end
    end

    defp select_repo(igniter, options) do
      case options[:repo] do
        nil ->
          IgniterEcto.select_repo(igniter,
            label: "Which Ecto repo should Durable use?"
          )

        repo_string ->
          repo = Module.concat([repo_string])
          {igniter, repo}
      end
    end

    defp generate_migration(igniter, repo) do
      migration_body = """
      def up do
        Durable.Migration.up()
      end

      def down do
        Durable.Migration.down()
      end
      """

      IgniterEcto.gen_migration(igniter, repo, "add_durable",
        body: migration_body,
        on_exists: :skip
      )
    end

    defp add_to_supervision_tree(igniter, repo) do
      child_spec =
        {Durable,
         {:code,
          quote do
            [repo: unquote(repo), queues: %{default: [concurrency: 10]}]
          end}}

      IgniterApplication.add_new_child(igniter, child_spec, after: [repo])
    end
  end
else
  defmodule Mix.Tasks.Durable.Install do
    @shortdoc "Installs Durable into your project | Install `igniter` to use"

    @moduledoc """
    #{@shortdoc}

    This task requires the `igniter` package to be installed.

    Add igniter to your dependencies in mix.exs:

        {:igniter, "~> 0.6"}

    Then run:

        mix deps.get
        mix durable.install
    """

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'durable.install' requires igniter. Please install igniter and try again.

      Add to your mix.exs:

          {:igniter, "~> 0.6"}

      Then run:

          mix deps.get
          mix durable.install

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
