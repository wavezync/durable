defmodule PhoenixDemo.Workflows.ArticleSyncWorkflow do
  @moduledoc """
  Syncs an article to the search index once its edits settle.

  Showcases workflow keys. Start it with `key: "article:<id>"`:

    * a burst of edits is debounced into one run with the newest input
      (`debounce:`),
    * an edit that arrives once the run has started is sent to it as the
      `article_updated` event (`on_duplicate: {:send_event, "article_updated"}`),
      and the run indexes that revision too.

  Input: `%{"id" => 42, "rev" => 3}`
  """

  use Durable
  use Durable.Helpers
  use Durable.Wait

  require Logger

  workflow "sync_article",
    debounce: [period: seconds(20), timeout: minutes(2)],
    on_duplicate: {:send_event, "article_updated"} do
    step(:index, fn data ->
      Logger.info("[ArticleSync] Indexing article #{data["id"]} at rev #{data["rev"]}")
      {:ok, assign(data, :indexed_rev, data["rev"])}
    end)

    step(:await_update, fn data ->
      update = wait_for_event("article_updated", timeout: minutes(5), timeout_value: nil)
      {:ok, assign(data, :update, update)}
    end)

    step(:index_update, fn data ->
      if update = data[:update] || data["update"] do
        Logger.info("[ArticleSync] Re-indexing article #{data["id"]} at rev #{update["rev"]}")
      end

      {:ok, data}
    end)
  end
end
