defmodule Durable.Scheduler.DSL do
  @moduledoc """
  Provides the `@schedule` decorator for declaring workflow schedules.

  ## Usage

      defmodule MyApp.DailyReport do
        use Durable
        use Durable.Scheduler.DSL

        @schedule cron: "0 9 * * *", timezone: "America/New_York"
        workflow "generate_report" do
          step :fetch_data do
            # ...
          end

          step :generate do
            # ...
          end
        end
      end

  Then register the module in your supervision tree:

      {Durable, repo: MyApp.Repo, scheduled_modules: [MyApp.DailyReport]}

  ## Options

  - `:cron` - Cron expression (required)
  - `:name` - Schedule name (defaults to workflow name)
  - `:timezone` - Timezone for cron evaluation (default: "UTC")
  - `:input` - Static input for each execution (default: %{})
  - `:queue` - Queue to run on (default: :default)

  """

  @doc """
  Injects schedule handling into the calling module.
  """
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :schedule, accumulate: false)
      Module.register_attribute(__MODULE__, :durable_schedules, accumulate: true)

      @before_compile Durable.Scheduler.DSL
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    schedules = Module.get_attribute(env.module, :durable_schedules) || []

    quote do
      @doc """
      Returns a list of schedule definitions declared in this module.
      """
      @spec __schedules__() :: [map()]
      def __schedules__ do
        unquote(Macro.escape(schedules))
      end
    end
  end

  @doc """
  Called internally to capture the @schedule attribute before a workflow.

  This function is used by patching the workflow macro to capture schedules.
  """
  def capture_schedule(module, workflow_name) do
    case Module.get_attribute(module, :schedule) do
      nil ->
        :ok

      schedule_opts when is_list(schedule_opts) ->
        cron = Keyword.fetch!(schedule_opts, :cron)

        schedule_def = %{
          workflow: workflow_name,
          cron: cron,
          name: Keyword.get(schedule_opts, :name),
          timezone: Keyword.get(schedule_opts, :timezone),
          input: Keyword.get(schedule_opts, :input),
          queue: Keyword.get(schedule_opts, :queue)
        }

        Module.put_attribute(module, :durable_schedules, schedule_def)
        Module.delete_attribute(module, :schedule)
        :ok
    end
  end
end
