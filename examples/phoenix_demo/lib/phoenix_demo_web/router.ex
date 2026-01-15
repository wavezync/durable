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

    # Redirect home to workflows dashboard
    get "/", PageController, :home

    # Workflow routes
    live "/workflows", WorkflowLive, :index
    live "/workflows/new", DocumentLive, :new
    live "/workflows/:id", WorkflowDetailLive, :show

    # Approval routes
    live "/approvals", ApprovalLive, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", PhoenixDemoWeb do
  #   pipe_through :api
  # end
end
