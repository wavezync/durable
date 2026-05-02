defmodule PhoenixDemoWeb.Router do
  use PhoenixDemoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PhoenixDemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PhoenixDemoWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/executions", ExecutionsLive, :index
    live "/executions/:id", WorkflowDetailLive, :show
    live "/pending-inputs", PendingInputsLive, :index
    live "/pending-events", PendingEventsLive, :index
    live "/schedules", SchedulesLive, :index

    # Legacy redirects so older bookmarks keep working.
    live "/workflows", ExecutionsLive, :index
    live "/workflows/:id", WorkflowDetailLive, :show
  end

  # Durable Dashboard — one line, mounts at /dashboard with its own
  # pipelines (asset routes skip CSRF for cross-origin script-tag fetches).
  use DurableDashboard.Router, mount: "/dashboard", durable: Durable
end
