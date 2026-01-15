defmodule PhoenixDemoWeb.DocumentLive do
  @moduledoc """
  LiveView for uploading documents and starting processing workflows.
  Supports actual file uploads with real processing.
  """

  use PhoenixDemoWeb, :live_view

  alias PhoenixDemo.Workflows.DocumentWorkflow

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Upload Document", workflow_id: nil, error: nil)
     |> allow_upload(:document,
       accept: ~w(.pdf .txt .csv .md .json .xml),
       max_entries: 1,
       max_file_size: 10_000_000
     )}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :document, ref)}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    case uploaded_entries(socket, :document) do
      {[_ | _], []} ->
        # Process the upload
        [result] =
          consume_uploaded_entries(socket, :document, fn %{path: path}, entry ->
            # Save file to uploads directory
            filename = entry.client_name
            dest_path = Path.join(uploads_dir(), "#{entry.uuid}_#{filename}")
            File.cp!(path, dest_path)

            {:ok,
             %{
               "filename" => filename,
               "path" => dest_path,
               "size" => entry.client_size,
               "content_type" => entry.client_type
             }}
          end)

        # Start the workflow with file info
        case Durable.start(DocumentWorkflow, result) do
          {:ok, workflow_id} ->
            Phoenix.PubSub.broadcast(
              PhoenixDemo.PubSub,
              "workflows",
              {:workflow_started, workflow_id}
            )

            {:noreply,
             socket
             |> assign(workflow_id: workflow_id, error: nil)
             |> put_flash(:info, "Document uploaded and workflow started!")}

          {:error, reason} ->
            {:noreply, assign(socket, error: "Failed to start workflow: #{inspect(reason)}")}
        end

      {[], []} ->
        {:noreply, assign(socket, error: "Please select a file to upload")}

      {_, [_ | _]} ->
        {:noreply, socket}
    end
  end

  defp uploads_dir do
    Path.join(:code.priv_dir(:phoenix_demo), "uploads")
  end

  defp error_to_string(:too_large), do: "File is too large (max 10MB)"
  defp error_to_string(:not_accepted), do: "File type not accepted"
  defp error_to_string(:too_many_files), do: "Only one file allowed"
  defp error_to_string(err), do: "Error: #{inspect(err)}"

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Upload Document
      <:subtitle>Upload a document to start the processing workflow</:subtitle>
      <:actions>
        <.button navigate={~p"/workflows"}>
          <.icon name="hero-arrow-left" class="size-4 mr-1" /> Back to Dashboard
        </.button>
      </:actions>
    </.header>

    <div class="mt-8">
      <div class="card bg-base-200 shadow-xl">
        <div class="card-body">
          <h2 class="card-title">Select Document</h2>

          <.form for={%{}} phx-change="validate" phx-submit="submit" class="mt-4">
            <div
              class="border-2 border-dashed border-base-300 rounded-lg p-8 text-center hover:border-primary transition-colors"
              phx-drop-target={@uploads.document.ref}
            >
              <.live_file_input upload={@uploads.document} class="hidden" />

              <div :if={@uploads.document.entries == []}>
                <.icon name="hero-cloud-arrow-up" class="size-12 mx-auto text-base-content/40" />
                <p class="mt-2 text-base-content/70">
                  Drag and drop a file here, or
                  <label for={@uploads.document.ref} class="link link-primary cursor-pointer">
                    browse
                  </label>
                </p>
                <p class="text-sm text-base-content/50 mt-1">
                  Supported: PDF, TXT, CSV, MD, JSON, XML (max 10MB)
                </p>
              </div>

              <%= for entry <- @uploads.document.entries do %>
                <div class="flex items-center justify-between bg-base-300 rounded-lg p-4">
                  <div class="flex items-center gap-3">
                    <.icon name={file_icon(entry.client_name)} class="size-8 text-primary" />
                    <div class="text-left">
                      <p class="font-semibold">{entry.client_name}</p>
                      <p class="text-sm text-base-content/60">
                        {format_bytes(entry.client_size)}
                      </p>
                    </div>
                  </div>
                  <button
                    type="button"
                    phx-click="cancel-upload"
                    phx-value-ref={entry.ref}
                    class="btn btn-ghost btn-sm btn-circle"
                  >
                    <.icon name="hero-x-mark" class="size-5" />
                  </button>
                </div>

                <div :if={entry.progress > 0 and entry.progress < 100} class="mt-2">
                  <progress class="progress progress-primary w-full" value={entry.progress} max="100">
                  </progress>
                </div>

                <%= for err <- upload_errors(@uploads.document, entry) do %>
                  <p class="text-error text-sm mt-2">{error_to_string(err)}</p>
                <% end %>
              <% end %>
            </div>

            <div :if={@error} class="alert alert-error mt-4">
              <.icon name="hero-exclamation-circle" class="size-5" />
              <span>{@error}</span>
            </div>

            <div class="card-actions justify-end mt-6">
              <.button
                type="submit"
                variant="primary"
                disabled={@uploads.document.entries == []}
              >
                <.icon name="hero-arrow-up-tray" class="size-4 mr-1" /> Upload & Process
              </.button>
            </div>
          </.form>
        </div>
      </div>

      <div :if={@workflow_id} class="mt-6">
        <div class="alert alert-success">
          <.icon name="hero-check-circle" class="size-6" />
          <div>
            <h3 class="font-bold">Workflow Started!</h3>
            <p class="text-sm">
              Workflow ID: <code class="font-mono">{@workflow_id}</code>
            </p>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/workflows/#{@workflow_id}"} class="btn btn-sm">
              View Progress
            </.link>
          </div>
        </div>
      </div>

      <div class="mt-8 grid md:grid-cols-2 gap-6">
        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title text-base">
              <.icon name="hero-cog-6-tooth" class="size-5" /> Processing Steps
            </h3>
            <ul class="steps steps-vertical text-sm">
              <li class="step step-primary">Validate file format</li>
              <li class="step">Analyze content (size, lines, etc.)</li>
              <li class="step">Check if approval needed</li>
              <li class="step">Transform & generate report</li>
            </ul>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title text-base">
              <.icon name="hero-shield-check" class="size-5" /> Approval Rules
            </h3>
            <div class="space-y-2 text-sm">
              <div class="flex items-center gap-2">
                <span class="badge badge-warning badge-sm">Requires Approval</span>
                <span>PDF files</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="badge badge-success badge-sm">Auto-Approved</span>
                <span>TXT, CSV, MD, JSON, XML</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp file_icon(filename) do
    ext = Path.extname(filename) |> String.downcase()

    case ext do
      ".pdf" -> "hero-document"
      ".txt" -> "hero-document-text"
      ".csv" -> "hero-table-cells"
      ".md" -> "hero-document-text"
      ".json" -> "hero-code-bracket"
      ".xml" -> "hero-code-bracket"
      _ -> "hero-document"
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
