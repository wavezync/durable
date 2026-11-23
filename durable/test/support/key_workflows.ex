defmodule Durable.KeyWorkflows do
  @moduledoc false
  # Keyed workflows for the live key tests. In test/support, not a test file,
  # so a second node can load them.

  alias Durable.IntegrationProbe, as: Probe

  defmodule Again do
    @moduledoc false
    use Durable

    workflow "kw_again", on_duplicate: :run_again do
      step :work, fn data -> Durable.KeyWorkflows.body(data) end
    end
  end

  @doc """
  A step that says when it runs, and for which key and input, counted under
  `{:key, key}` so the peak says whether two runs of a key overlapped. `"hold"`
  waits for the flag `{:go, v}`, `"ms"` sleeps, `"fail"` fails the run.
  """
  def body(data) do
    key = data["key"]

    Probe.inside([{:key, key}], fn ->
      Probe.note({:ran, key, data["v"]})
      if data["hold"], do: Probe.wait_for({:go, data["v"]})
      Process.sleep(data["ms"] || 0)
    end)

    if data["fail"], do: {:fail, "told to"}, else: {:ok, data}
  end

  @doc "The inputs (`v`) of `key` in the order their step began."
  def ran(key), do: for({{:ran, ^key, v}, _, _} <- Probe.log(), do: v)
end
