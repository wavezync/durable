defmodule PhoenixDemo.Workflows.ContentModerationWorkflow do
  @moduledoc """
  Slimmed-down content moderation: parallel mock-AI scans aggregate to a
  max-score, branch routes based on severity, and ambiguous content is sent
  to a human via `wait_for_choice`.

  Showcases: `parallel into:`, `branch on:`, `wait_for_choice`.

  Input:
      %{"content_id" => "POST-123", "content_type" => "image"}
  """

  use Durable
  use Durable.Helpers
  use Durable.Context
  use Durable.Wait

  require Logger

  workflow "moderate_content", timeout: hours(24) do
    step :ingest, fn data ->
      content_id = data["content_id"] || "POST-#{:rand.uniform(99_999)}"
      content_type = data["content_type"] || "text"

      Logger.info("[Mod] Ingesting #{content_id} (#{content_type})")
      put_context(:content_id, content_id)
      put_context(:content_type, content_type)

      {:ok, assign(data, "content_id", content_id)}
    end

    parallel into: fn _ctx, results ->
      scores = %{
        "toxicity" => extract_score(results, :toxicity_scan),
        "nsfw" => extract_score(results, :nsfw_scan),
        "spam" => extract_score(results, :spam_scan)
      }

      max_score =
        scores
        |> Map.values()
        |> Enum.max()

      Logger.info("[Mod] Scan complete: #{inspect(scores)} (max=#{max_score})")

      put_context(:scores, scores)
      put_context(:max_score, max_score)

      {:ok, %{"scores" => scores, "max_score" => max_score}}
    end do
      step :toxicity_scan, fn _data ->
        Process.sleep(:rand.uniform(300))
        score = :rand.uniform(100) / 100
        {:ok, %{score: score, model: "toxicity-v3"}}
      end

      step :nsfw_scan, fn _data ->
        Process.sleep(:rand.uniform(300))
        score = :rand.uniform(100) / 100
        {:ok, %{score: score, model: "nsfw-v2"}}
      end

      step :spam_scan, fn _data ->
        Process.sleep(:rand.uniform(300))
        score = :rand.uniform(100) / 100
        {:ok, %{score: score, model: "spam-v4"}}
      end
    end

    branch on: fn _data ->
      max = get_context(:max_score) || 0

      cond do
        max > 0.85 -> :high
        max > 0.4 -> :medium
        true -> :low
      end
    end do
      :high ->
        step :auto_remove, fn _data ->
          content_id = get_context(:content_id)
          Logger.info("[Mod] Auto-removed #{content_id} (high score)")

          {:ok,
           %{
             "content_id" => content_id,
             "action" => "auto_removed",
             "scores" => get_context(:scores)
           }}
        end

      :medium ->
        step :request_human_review, fn data ->
          content_id = get_context(:content_id)

          verdict =
            wait_for_choice("verdict",
              prompt: "Review flagged content #{content_id}",
              choices: [
                %{value: "approve", label: "Approve"},
                %{value: "warn", label: "Add content warning"},
                %{value: "remove", label: "Remove"}
              ],
              metadata: %{
                "content_id" => content_id,
                "content_type" => get_context(:content_type),
                "scores" => get_context(:scores)
              },
              timeout: hours(24),
              timeout_value: "warn"
            )

          Logger.info("[Mod] Human verdict for #{content_id}: #{verdict}")
          {:ok, assign(data, "verdict", verdict)}
        end

        step :apply_verdict, fn data ->
          content_id = get_context(:content_id)
          verdict = data["verdict"]

          {:ok,
           %{
             "content_id" => content_id,
             "action" => verdict,
             "scores" => get_context(:scores)
           }}
        end

      :low ->
        step :auto_approve, fn _data ->
          content_id = get_context(:content_id)
          Logger.info("[Mod] Auto-approved #{content_id} (low score)")

          {:ok,
           %{
             "content_id" => content_id,
             "action" => "auto_approved",
             "scores" => get_context(:scores)
           }}
        end
    end
  end

  defp extract_score(results, key) do
    case Map.get(results, key) do
      {:ok, %{score: s}} -> s
      %{score: s} -> s
      _ -> 0
    end
  end
end
