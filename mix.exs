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

  # Build an alias that runs `mix <command>` in each sub-app as its own OS
  # process. We invoke `elixir -S mix` (rather than `mix` directly) so we can
  # pass `--erl "-elixir ansi_enabled <bool>"`: each child's output is captured
  # via `into:` (a pipe, not a TTY), so the child would otherwise disable ANSI
  # and we'd lose colored test/credo/compiler output. Forwarding the root's
  # `IO.ANSI.enabled?/0` keeps colors when the workspace runs in a terminal and
  # correctly drops them when redirected (e.g. CI). A non-zero exit from any
  # sub-app makes the whole workspace task fail.
  defp cmd(command) do
    ansi = IO.ANSI.enabled?()
    base = ["--erl", "-elixir ansi_enabled #{ansi}", "-S", "mix", command]

    for app <- @apps do
      fn args ->
        {_, code} =
          System.cmd("elixir", base ++ args,
            into: IO.binstream(:stdio, :line),
            cd: app
          )

        if code > 0, do: System.at_exit(fn _ -> exit({:shutdown, 1}) end)
      end
    end
  end
end
