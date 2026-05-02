defmodule DurableDashboard.LayoutsTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Layout.{Breadcrumb, Sidebar}
  alias DurableDashboard.Layouts

  setup do
    previous = Application.get_env(:durable_dashboard, :dev_mode)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:durable_dashboard, :dev_mode)
      else
        Application.put_env(:durable_dashboard, :dev_mode, previous)
      end
    end)

    :ok
  end

  test "root loads the dev stylesheet before body content" do
    Application.put_env(:durable_dashboard, :dev_mode, true)

    html =
      render_component(&Layouts.root/1,
        config: %{live_socket_path: "/live", base_path: "/dashboard"},
        inner_content: Phoenix.HTML.raw(~s(<main id="dashboard-content"></main>))
      )

    stylesheet = ~s(href="http://localhost:5173/src/index.css")

    assert html =~ stylesheet
    assert offset(html, stylesheet) < offset(html, "</head>")
    assert offset(html, stylesheet) < offset(html, ~s(<body))
  end

  test "sidebar uses LiveView navigation for internal page switches" do
    html =
      render_component(&Sidebar.sidebar/1,
        base_path: "/dashboard",
        current_path: "/dashboard"
      )

    assert html =~ ~s(href="/dashboard/workflows")
    assert html =~ ~s(data-phx-link="redirect")
    refute html =~ ~s(<a href="/dashboard/workflows" class=)
  end

  test "breadcrumb links use LiveView navigation" do
    html =
      render_component(&Breadcrumb.breadcrumb/1,
        crumbs: [
          %{label: "Workflows", href: "/dashboard/workflows"},
          %{label: "abc123"}
        ]
      )

    assert html =~ ~s(href="/dashboard/workflows")
    assert html =~ ~s(data-phx-link="redirect")
  end

  defp offset(string, pattern) do
    case :binary.match(string, pattern) do
      {index, _length} -> index
      :nomatch -> flunk("expected #{inspect(pattern)} in rendered HTML")
    end
  end
end
