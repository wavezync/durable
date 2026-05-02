defmodule Mix.Tasks.SeedWorkflows do
  @moduledoc """
  Seed the demo database with varied workflow executions for dashboard testing.

  Run with: mix seed_workflows

  This starts multiple workflows across all 3 demo workflow types with diverse
  inputs so the dashboard has interesting data to display — completed, failed,
  running, and waiting-for-input workflows.
  """

  use Mix.Task

  @shortdoc "Seed demo workflows for dashboard testing"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    IO.puts("\n🚀 Seeding demo workflows...\n")

    # ── Document workflows ────────────────────────────────────────────────
    seed_document_workflows()

    # ── Order workflows ───────────────────────────────────────────────────
    seed_order_workflows()

    # ── Onboarding workflows ──────────────────────────────────────────────
    seed_onboarding_workflows()

    # ── Content moderation workflows ──────────────────────────────────────
    seed_moderation_workflows()

    IO.puts("\n✅ Seeding complete! Visit http://localhost:4000/dashboard to see the results.\n")

    # Give workflows a moment to start executing
    Process.sleep(3000)
  end

  defp seed_document_workflows do
    alias PhoenixDemo.Workflows.DocumentWorkflow

    # Create a temp file for successful processing
    dir = System.tmp_dir!()

    # 1. Successful text file
    txt_path = Path.join(dir, "report.txt")
    File.write!(txt_path, "This is a quarterly report.\nIt contains important data.\nTotal revenue: $1.2M")
    start("Document (text)", DocumentWorkflow, %{
      "filename" => "report.txt",
      "path" => txt_path,
      "content_type" => "text/plain"
    })

    # 2. Successful JSON file
    json_path = Path.join(dir, "config.json")
    File.write!(json_path, Jason.encode!(%{version: "2.0", features: ["auth", "billing", "api"]}))
    start("Document (json)", DocumentWorkflow, %{
      "filename" => "config.json",
      "path" => json_path,
      "content_type" => "application/json"
    })

    # 3. PDF requiring approval (will wait for input)
    pdf_path = Path.join(dir, "contract.pdf")
    File.write!(pdf_path, "%PDF-1.4 fake pdf content for testing")
    start("Document (pdf, needs approval)", DocumentWorkflow, %{
      "filename" => "contract.pdf",
      "path" => pdf_path,
      "content_type" => "application/pdf"
    })

    # 4. Invalid file (will fail)
    start("Document (invalid)", DocumentWorkflow, %{
      "filename" => "virus.exe",
      "path" => "/nonexistent/path",
      "content_type" => "application/octet-stream"
    })
  end

  defp seed_order_workflows do
    alias PhoenixDemo.Workflows.OrderWorkflow

    # 1. Physical order (low value, auto-approved)
    start("Order (physical, low value)", OrderWorkflow, %{
      "order_id" => "ORD-1001",
      "type" => "physical",
      "total" => 49.99,
      "customer_email" => "alice@example.com",
      "items" => [%{"name" => "USB Cable", "qty" => 2, "price" => 24.99}]
    })

    # 2. Digital order (auto-approved)
    start("Order (digital)", OrderWorkflow, %{
      "order_id" => "ORD-1002",
      "type" => "digital",
      "total" => 9.99,
      "customer_email" => "bob@example.com",
      "items" => [%{"name" => "E-Book: Elixir in Action", "qty" => 1, "price" => 9.99}]
    })

    # 3. Subscription
    start("Order (subscription)", OrderWorkflow, %{
      "order_id" => "ORD-1003",
      "type" => "subscription",
      "total" => 29.99,
      "customer_email" => "carol@example.com",
      "items" => [%{"name" => "Pro Plan (monthly)", "qty" => 1, "price" => 29.99}]
    })

    # 4. High-value physical order (needs approval, will wait)
    start("Order (high value, needs approval)", OrderWorkflow, %{
      "order_id" => "ORD-1004",
      "type" => "physical",
      "total" => 1299.99,
      "customer_email" => "dave@example.com",
      "items" => [
        %{"name" => "MacBook Air", "qty" => 1, "price" => 1199.99},
        %{"name" => "USB-C Hub", "qty" => 1, "price" => 100.00}
      ]
    })

    # 5. Zero-value order (will fail validation)
    start("Order (invalid, zero total)", OrderWorkflow, %{
      "order_id" => "ORD-1005",
      "type" => "physical",
      "total" => 0,
      "customer_email" => "eve@example.com"
    })
  end

  defp seed_onboarding_workflows do
    alias PhoenixDemo.Workflows.OnboardingWorkflow

    # 1. Engineering hire (will wait for form + approval)
    start("Onboarding (engineer)", OnboardingWorkflow, %{
      "employee_name" => "Alice Chen",
      "department" => "engineering",
      "role" => "Senior Backend Engineer",
      "start_date" => Date.add(Date.utc_today(), 14) |> Date.to_iso8601()
    })

    # 2. Design hire
    start("Onboarding (designer)", OnboardingWorkflow, %{
      "employee_name" => "Bob Martinez",
      "department" => "design",
      "role" => "Product Designer",
      "start_date" => Date.add(Date.utc_today(), 7) |> Date.to_iso8601()
    })
  end

  defp seed_moderation_workflows do
    alias PhoenixDemo.Workflows.ContentModerationWorkflow

    # 1. Text post
    start("Moderation (text post)", ContentModerationWorkflow, %{
      "content_id" => "POST-5001",
      "content_type" => "text",
      "content_url" => "https://cdn.example.com/posts/5001",
      "reported_by" => "user42@example.com",
      "report_count" => 1
    })

    # 2. Image report
    start("Moderation (image)", ContentModerationWorkflow, %{
      "content_id" => "IMG-5002",
      "content_type" => "image",
      "content_url" => "https://cdn.example.com/images/5002.jpg",
      "reported_by" => "moderator@example.com",
      "report_count" => 3
    })

    # 3. Video report
    start("Moderation (video)", ContentModerationWorkflow, %{
      "content_id" => "VID-5003",
      "content_type" => "video",
      "content_url" => "https://cdn.example.com/videos/5003.mp4",
      "reported_by" => "trust-safety@example.com",
      "report_count" => 10
    })
  end

  defp start(label, module, input) do
    case Durable.start(module, input) do
      {:ok, id} ->
        IO.puts("  ✓ #{label} → #{id}")

      {:error, reason} ->
        IO.puts("  ✗ #{label} → ERROR: #{inspect(reason)}")
    end
  end
end
