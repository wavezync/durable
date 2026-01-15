defmodule PhoenixDemoWeb.PageController do
  use PhoenixDemoWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/workflows")
  end
end
