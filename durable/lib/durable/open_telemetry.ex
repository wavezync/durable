# `opentelemetry_api` is optional, so these modules only exist in apps that
# install it, the same way `Durable.Telemetry.metrics/0` needs `telemetry_metrics`.
if Code.ensure_loaded?(:otel_tracer) do
  defmodule Durable.OpenTelemetry.IdGenerator do
    @moduledoc """
    Gives a step attempt's span the ids Durable has already stored.

    Configure it as the SDK's id generator (see `Durable.OpenTelemetry`). Every
    other span gets the SDK's usual random ids.
    """

    @compile {:no_warn_undefined, :otel_id_generator}

    @trace_key {__MODULE__, :trace_id}
    @span_key {__MODULE__, :span_id}

    @doc false
    def generate_trace_id, do: Process.get(@trace_key) || :otel_id_generator.generate_trace_id()

    @doc false
    def generate_span_id, do: Process.get(@span_key) || :otel_id_generator.generate_span_id()

    @doc false
    # The SDK's generator is global and takes no arguments, so the ids reach it
    # through the process that's starting the span.
    def with_ids(trace_id, span_id, fun) do
      Process.put(@trace_key, trace_id)
      Process.put(@span_key, span_id)

      try do
        fun.()
      after
        Process.delete(@trace_key)
        Process.delete(@span_key)
      end
    end
  end

  defmodule Durable.OpenTelemetry do
    @moduledoc """
    Reports each step attempt as an OpenTelemetry span.

    ## Setup

    Add the SDK, point its id generator at Durable, and attach the handlers
    when your application starts:

        # mix.exs
        {:opentelemetry, "~> 1.5"}

        # config/config.exs
        config :opentelemetry, id_generator: Durable.OpenTelemetry.IdGenerator

        # application.ex
        Durable.OpenTelemetry.setup()

    ## What you get

      * The top run's id is the trace id, so a run and every child and parallel
        run under it are one trace, across sleeps, retries and nodes.
      * Each step attempt is a span, its id taken from the attempt's row. The
        log lines saved on that row carry the same two ids.
      * While a step runs, its span is current, so your own spans nest under
        it and OpenTelemetry adds `otel_trace_id` and `otel_span_id` to its
        Logger lines. In a `Task`, wrap the function in
        `Durable.Context.bind/1` to keep them.
      * A compensation is one span covering all its attempts, in the same
        trace, with an id of its own.
      * An attempt that dies still gets a span, recorded by whoever finds out,
        marked as an error unless it was cancelled or handed back.

    Durable doesn't export anything itself: your SDK configuration decides
    where spans and logs go.

    The SDK drops a span still open after 30 minutes. For longer steps, raise
    its `span_ttl`: `config :opentelemetry, sweeper: %{span_ttl: :timer.hours(4)}`.
    """

    require Logger

    alias Durable.OpenTelemetry.IdGenerator

    @handler "durable-opentelemetry"
    @events for kind <- [:step, :compensation],
                phase <- [:start, :stop, :exception],
                do: [:durable, kind, phase]

    @doc """
    Attaches the telemetry handlers. Call it once, when your application starts.

    Returns `{:error, :id_generator_not_configured}`, and logs why, if the SDK
    isn't using `Durable.OpenTelemetry.IdGenerator`: without it a run's attempts
    wouldn't share a trace.
    """
    @spec setup() :: :ok | {:error, :id_generator_not_configured | :already_exists}
    def setup do
      if id_generator_configured?() do
        :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, nil)
      else
        Logger.warning(
          "[Durable] OpenTelemetry not set up: add " <>
            "`config :opentelemetry, id_generator: #{inspect(IdGenerator)}`"
        )

        {:error, :id_generator_not_configured}
      end
    end

    defp id_generator_configured? do
      generator = Application.get_env(:opentelemetry, :id_generator)
      env = System.get_env("OTEL_ID_GENERATOR")
      generator == IdGenerator or env == Atom.to_string(IdGenerator)
    end

    @doc false
    def handle_event([:durable, kind, :start], _measurements, meta, _config) do
      previous = :otel_tracer.current_span_ctx()
      span = start_span(kind, meta, :opentelemetry.timestamp())

      :otel_tracer.set_current_span(span)
      Process.put(span_key(meta), {span, previous})
    end

    def handle_event([:durable, kind, :stop], measurements, meta, _config) do
      finish(kind, meta, measurements, &record_result(&1, meta))
    end

    def handle_event([:durable, kind, :exception], measurements, meta, _config) do
      message = Exception.format_banner(meta.kind, meta.reason)
      finish(kind, meta, measurements, &set_error(&1, message))
    end

    defp finish(kind, meta, measurements, record) do
      case Process.delete(span_key(meta)) do
        {span, previous} ->
          record.(span)
          :otel_span.end_span(span)
          restore_current(previous)

        nil ->
          # Ended by someone other than the process that ran it, which may be
          # gone along with its node. The span is made now, back-dated, and has
          # the same ids; one left open on a live node is dropped unexported.
          started = :opentelemetry.timestamp() - measurements.duration
          span = start_span(kind, meta, started)
          record.(span)
          :otel_span.end_span(span)
      end
    end

    defp start_span(kind, meta, start_time) do
      opts = %{attributes: attributes(kind, meta), kind: :internal, start_time: start_time}

      IdGenerator.with_ids(trace_id(meta), span_id(kind, meta), fn ->
        :otel_tracer.start_span(:otel_ctx.new(), tracer(), span_name(kind, meta), opts)
      end)
    end

    defp tracer, do: :opentelemetry.get_tracer(:durable)

    defp span_key(meta), do: {__MODULE__, meta.telemetry_span_context}

    defp trace_id(meta) do
      %{trace_id: hex} = Durable.Telemetry.log_ids(meta.root_workflow_id, meta.root_workflow_id)
      to_integer(hex)
    end

    defp span_id(:step, meta) do
      %{span_id: hex} = Durable.Telemetry.log_ids(meta.root_workflow_id, meta.step_execution_id)
      to_integer(hex)
    end

    defp span_id(:compensation, _meta), do: nil

    defp to_integer(hex), do: hex |> Base.decode16!(case: :lower) |> :binary.decode_unsigned()

    defp span_name(:step, meta), do: "#{meta.workflow}.#{meta.step}"
    defp span_name(:compensation, meta), do: "#{meta.workflow}.#{meta.compensation}"

    defp attributes(:step, meta) do
      Map.merge(run_attributes(meta), %{
        "durable.step" => to_string(meta.step),
        "durable.attempt" => meta.attempt
      })
    end

    defp attributes(:compensation, meta) do
      Map.merge(run_attributes(meta), %{
        "durable.compensation" => to_string(meta.compensation),
        "durable.step" => to_string(meta.step)
      })
    end

    defp run_attributes(meta) do
      %{
        "durable.workflow" => to_string(meta.workflow),
        "durable.workflow_id" => meta.workflow_id
      }
    end

    defp record_result(span, %{result: :error} = meta) do
      :otel_span.set_attribute(span, "durable.result", "error")
      set_error(span, error_text(meta))
    end

    defp record_result(span, %{result: result}) do
      :otel_span.set_attribute(span, "durable.result", to_string(result))
    end

    defp set_error(span, message) do
      :otel_span.set_status(span, :opentelemetry.status(:error, message))
    end

    defp error_text(%{error: %{type: type, message: message}}), do: "#{type}: #{message}"
    defp error_text(_meta), do: "failed"

    defp restore_current(previous) do
      :otel_tracer.set_current_span(previous)

      # With no span to restore, the SDK leaves the old ids in Logger metadata.
      if previous == :undefined do
        # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
        Logger.metadata(otel_trace_id: nil, otel_span_id: nil, otel_trace_flags: nil)
      end
    end
  end
end
