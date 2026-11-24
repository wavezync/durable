defmodule DurableDashboard.Access do
  @moduledoc """
  Who may change things from the dashboard.

  Three levels:

    * `:viewer` — sees everything, changes nothing. The default when no
      resolver is configured, so mounting the dashboard never grants writes
      by accident.
    * `:operator` — retry, rerun and cancel runs; answer inputs; send events;
      pause and resume queues; run a schedule now; release a workflow key.
    * `:admin` — everything above, plus bulk actions over 100 runs, enabling
      and disabling schedules, and pruning on demand.

  Configure a resolver on the router:

      use DurableDashboard.Router,
        mount: "/durable",
        resolver: MyAppWeb.DurableResolver

      defmodule MyAppWeb.DurableResolver do
        @behaviour DurableDashboard.Access

        @impl true
        def resolve_user(conn), do: conn.assigns[:current_user]

        @impl true
        def resolve_access(%{role: :admin}), do: :admin
        def resolve_access(%{role: :ops}), do: :operator
        def resolve_access(_user), do: :viewer
      end

  Every action the dashboard performs emits `[:durable_dashboard, :action]`
  with `%{count}` (runs affected) and metadata `:action`, `:user`, `:ids` and
  `:result` — attach a handler to keep an audit trail.
  """

  @type level :: :viewer | :operator | :admin

  @doc "The user behind this request, or nil. Only `user_label/1` of it is kept."
  @callback resolve_user(Plug.Conn.t()) :: term()

  @doc "The access level for that user."
  @callback resolve_access(user :: term()) :: level()

  @levels %{viewer: 0, operator: 1, admin: 2}

  @doc false
  # live_session `session` MFA: runs once per page load with the conn.
  def session(_conn, config, nil), do: %{"config" => config, "access" => "viewer", "user" => nil}

  def session(conn, config, resolver) do
    user = resolver.resolve_user(conn)
    access = resolver.resolve_access(user)

    unless Map.has_key?(@levels, access) do
      raise ArgumentError,
            "#{inspect(resolver)}.resolve_access/1 must return :viewer, :operator or :admin, " <>
              "got: #{inspect(access)}"
    end

    %{"config" => config, "access" => Atom.to_string(access), "user" => user_label(user)}
  end

  @doc false
  # on_mount hook: puts `:access`, `:user` and `:dashboard_label` (what the sidebar
  # names this dashboard by) on every dashboard LiveView.
  def on_mount(:default, _params, session, socket) do
    access =
      case session["access"] do
        level when level in ["viewer", "operator", "admin"] -> String.to_existing_atom(level)
        _ -> :viewer
      end

    {:cont,
     Phoenix.Component.assign(socket,
       access: access,
       user: session["user"],
       dashboard_label: dashboard_label(session["config"])
     )}
  end

  # The router's `:label`, else the database the instance's repo is on. Read
  # once a mount: `repo.config/0` runs the repo's `init/2` each time.
  defp dashboard_label(%{durable: durable} = config) do
    {db, prefix} =
      case Durable.Config.get_safe(durable) do
        %{repo: repo, prefix: prefix} -> {repo.config(), prefix}
        _ -> {[], "durable"}
      end

    %{
      text: Map.get(config, :label) || db[:database] || inspect(durable),
      where:
        db[:database] && Enum.join(Enum.reject([db[:database], db[:hostname]], &is_nil/1), " on "),
      prefix: prefix
    }
  end

  defp dashboard_label(_config), do: nil

  @doc "True when `access` is at least `required`."
  @spec allowed?(level(), level()) :: boolean()
  def allowed?(access, required), do: Map.fetch!(@levels, access) >= Map.fetch!(@levels, required)

  @doc false
  # Runs `fun` only when the socket's access allows it, and records the
  # attempt either way.
  def perform(socket, required, action, ids, fun) do
    result =
      if allowed?(socket.assigns[:access] || :viewer, required),
        do: fun.(),
        else: {:error, :forbidden}

    :telemetry.execute(
      [:durable_dashboard, :action],
      %{count: length(ids)},
      %{
        action: action,
        user: socket.assigns[:user],
        ids: ids,
        result: outcome(result),
        durable: socket.assigns[:durable]
      }
    )

    result
  end

  defp outcome(:ok), do: :ok
  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome(other), do: other

  defp user_label(nil), do: nil
  defp user_label(%{email: email}) when is_binary(email), do: email
  defp user_label(%{name: name}) when is_binary(name), do: name
  defp user_label(user) when is_binary(user), do: user
  defp user_label(user), do: inspect(user, limit: 5)
end
