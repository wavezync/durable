defmodule PhoenixDemo.Workflows.ReindexArticleWorkflow do
  @moduledoc """
  Puts an article back in the search index after an edit. Editors save often:
  each save in the 10 seconds after the last gives the waiting run the newest
  text and restarts the wait, so a burst of saves is indexed once. A steady
  stream of saves still gets indexed within a minute.

  Showcases: a workflow key with `debounce: [period: seconds(10), timeout:
  minutes(1)]`.

  Input: %{"article_id" => "how-to-retry", "title" => "How to retry a step"}
  """

  use Durable
  use Durable.Helpers

  require Logger

  workflow "reindex_article", debounce: [period: seconds(10), timeout: minutes(1)] do
    step :render, fn article ->
      {:ok, assign(article, :words, 300 + :rand.uniform(1_200))}
    end

    step :index, fn article ->
      Logger.info("[Search] indexed #{article["article_id"]}: #{article["title"]}")
      {:ok, assign(article, :indexed, true)}
    end
  end
end
