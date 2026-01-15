defmodule PhoenixDemo.Workflows.DocumentWorkflow do
  @moduledoc """
  A document processing workflow that demonstrates Durable's capabilities.

  This workflow processes uploaded documents through several stages:
  1. Validate the document exists and is readable
  2. Analyze the content (count bytes, lines, words)
  3. Check if approval is needed (only for PDFs)
  4. Transform the data and generate a report

  PDFs require human approval; other file types are auto-approved.
  """

  use Durable
  use Durable.Helpers
  use Durable.Context
  use Durable.Wait

  @valid_extensions [".pdf", ".txt", ".csv", ".md", ".json", ".xml"]

  workflow "process_document", timeout: hours(24) do
    step(:validate_document, fn data ->
      # First step receives workflow input as data parameter
      filename = data["filename"] || ""
      path = data["path"]

      ext = Path.extname(filename) |> String.downcase()
      valid_ext? = ext in @valid_extensions
      file_exists? = path && File.exists?(path)

      cond do
        !valid_ext? ->
          {:error, %{reason: "Invalid file extension: #{ext}", filename: filename}}

        !file_exists? ->
          {:error, %{reason: "File not found", path: path}}

        true ->
          put_context(:filename, filename)
          put_context(:path, path)
          put_context(:extension, ext)
          put_context(:content_type, data["content_type"])
          put_context(:validated_at, DateTime.utc_now() |> DateTime.to_iso8601())

          {:ok, %{filename: filename, path: path, extension: ext, validated: true}}
      end
    end)

    step(:analyze_content, fn data ->
      path = data[:path]
      ext = data[:extension]

      # Get file stats
      {:ok, stat} = File.stat(path)
      size_bytes = stat.size

      # Analyze content based on file type
      analysis =
        case ext do
          ".pdf" ->
            # PDFs are binary, just get size
            %{
              "type" => "pdf",
              "size_bytes" => size_bytes,
              "size_human" => format_bytes(size_bytes),
              "note" => "PDF content analysis requires external tools"
            }

          ext when ext in [".txt", ".md", ".csv"] ->
            # Text files - count lines and words
            content = File.read!(path)
            lines = String.split(content, ~r/\r?\n/)
            words = String.split(content, ~r/\s+/, trim: true)

            %{
              "type" => "text",
              "size_bytes" => size_bytes,
              "size_human" => format_bytes(size_bytes),
              "line_count" => length(lines),
              "word_count" => length(words),
              "char_count" => String.length(content),
              "preview" => String.slice(content, 0, 500)
            }

          ".json" ->
            content = File.read!(path)

            case Jason.decode(content) do
              {:ok, decoded} ->
                %{
                  "type" => "json",
                  "size_bytes" => size_bytes,
                  "size_human" => format_bytes(size_bytes),
                  "valid_json" => true,
                  "top_level_type" => json_type(decoded),
                  "key_count" => if(is_map(decoded), do: map_size(decoded), else: nil),
                  "array_length" => if(is_list(decoded), do: length(decoded), else: nil)
                }

              {:error, _} ->
                %{
                  "type" => "json",
                  "size_bytes" => size_bytes,
                  "valid_json" => false,
                  "error" => "Invalid JSON format"
                }
            end

          ".xml" ->
            content = File.read!(path)
            lines = String.split(content, ~r/\r?\n/)

            %{
              "type" => "xml",
              "size_bytes" => size_bytes,
              "size_human" => format_bytes(size_bytes),
              "line_count" => length(lines),
              "preview" => String.slice(content, 0, 500)
            }

          _ ->
            %{
              "type" => "unknown",
              "size_bytes" => size_bytes,
              "size_human" => format_bytes(size_bytes)
            }
        end

      put_context(:analysis, analysis)
      put_context(:requires_approval, ext == ".pdf")
      put_context(:analyzed_at, DateTime.utc_now() |> DateTime.to_iso8601())

      {:ok, Map.merge(data, %{analysis: analysis, requires_approval: ext == ".pdf"})}
    end)

    decision(:check_approval_needed, fn data ->
      if data[:requires_approval] do
        {:ok, data}
      else
        # Skip approval for non-PDF files
        put_context(:approval_response, %{"auto_approved" => true, "reason" => "Non-PDF file"})
        {:goto, :transform_data, data}
      end
    end)

    step(:request_approval, fn data ->
      filename = get_context(:filename)
      analysis = get_context(:analysis)

      approval =
        wait_for_approval("document_approval",
          prompt: "Please review and approve this PDF document for processing",
          metadata: %{
            "filename" => filename,
            "analysis" => analysis
          }
        )

      put_context(:approval_response, approval)
      {:ok, Map.put(data, :approval, approval)}
    end)

    decision(:check_approval_result, fn data ->
      approval = get_context(:approval_response)

      cond do
        approval == :timeout ->
          {:goto, :handle_rejection, assign(data, :rejection_reason, "Approval timed out")}

        is_map(approval) and approval["approved"] == true ->
          {:ok, data}

        is_map(approval) and approval["auto_approved"] == true ->
          {:ok, data}

        true ->
          reason = if is_map(approval), do: approval["reason"], else: "Rejected by reviewer"
          {:goto, :handle_rejection, assign(data, :rejection_reason, reason)}
      end
    end)

    step(:transform_data, fn data ->
      analysis = get_context(:analysis)
      approval = get_context(:approval_response)

      transformed = %{
        "processed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "status" => "approved",
        "approval_type" =>
          if(is_map(approval) && approval["auto_approved"], do: "automatic", else: "manual"),
        "approved_by" => get_in(approval, ["approved_by"]) || "system",
        "analysis" => analysis,
        "checksum" => :crypto.hash(:sha256, Jason.encode!(analysis)) |> Base.encode16()
      }

      put_context(:transformed_data, transformed)
      {:ok, Map.put(data, :transformed, transformed)}
    end)

    step(:generate_report, fn _data ->
      filename = get_context(:filename)
      path = get_context(:path)
      analysis = get_context(:analysis)
      transformed = get_context(:transformed_data)

      report = %{
        "id" => Ecto.UUID.generate(),
        "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "filename" => filename,
        "status" => "completed",
        "summary" => %{
          "file_type" => analysis["type"],
          "size" => analysis["size_human"],
          "approval_type" => transformed["approval_type"],
          "processing_time_ms" => System.system_time(:millisecond)
        },
        "analysis" => analysis,
        "checksum" => transformed["checksum"]
      }

      put_context(:report, report)

      # Clean up the uploaded file
      if path && File.exists?(path) do
        File.rm(path)
      end

      # Broadcast completion
      Phoenix.PubSub.broadcast(
        PhoenixDemo.PubSub,
        "workflows",
        {:workflow_completed, workflow_id(), report}
      )

      {:ok, %{status: "completed", report: report}}
    end)

    step(:handle_rejection, fn data ->
      reason = data[:rejection_reason] || "Unknown reason"
      filename = get_context(:filename)
      path = get_context(:path)

      result = %{
        "status" => "rejected",
        "reason" => reason,
        "rejected_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "filename" => filename
      }

      put_context(:rejection, result)

      # Clean up the uploaded file
      if path && File.exists?(path) do
        File.rm(path)
      end

      # Broadcast rejection
      Phoenix.PubSub.broadcast(
        PhoenixDemo.PubSub,
        "workflows",
        {:workflow_rejected, workflow_id(), result}
      )

      {:ok, result}
    end)
  end

  # Helper functions
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp json_type(value) when is_map(value), do: "object"
  defp json_type(value) when is_list(value), do: "array"
  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_number(value), do: "number"
  defp json_type(value) when is_boolean(value), do: "boolean"
  defp json_type(nil), do: "null"
  defp json_type(_), do: "unknown"
end
