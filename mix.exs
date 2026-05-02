defmodule DurableWorkspace.MixProject do
  use Mix.Project

  @apps ~w(durable durable_dashboard)

  def project do
    [
      app: :durable_workspace,
      version: "0.0.0",
      elixir: "~> 1.15",
      deps: [
        {:durable, path: "durable"},
        {:durable_dashboard, path: "durable_dashboard"}
      ],
      aliases: [
        setup: cmd("deps.get"),
        compile: cmd("compile"),
        test: cmd("test"),
        format: cmd("format"),
        precommit: cmd("precommit")
      ]
    ]
  end

  defp cmd(command) do
    for app <- @apps do
      fn args ->
        {_, code} =
          System.cmd("mix", [command | args],
            into: IO.binstream(:stdio, :line),
            cd: app
          )

        if code > 0, do: System.at_exit(fn _ -> exit({:shutdown, 1}) end)
      end
    end
  end
end
