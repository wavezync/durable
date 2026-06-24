defmodule DurableDashboard.Components.Workflow.LogLine do
  @moduledoc """
  A single dense, Grafana-style log line — the shared visual unit used by both
  the page-level `LogsTab` and the step inspector's logs tab so they render
  identically. Stateless `Phoenix.Component`.

  Each `entry` is a map with `"level"`, `"message"`, `"timestamp"`, optional
  `"source"`, `"metadata"`, and `"__step__"` (the originating step name, only
  meaningful on the page-level tab).

  The collapsed line shows a one-liner; clicking expands a clean key/value
  fields table plus the message. A message that embeds structured data — pure
  JSON *or* an Elixir map (`%{...}`, including the common
  `"label: \#{inspect(map)}"` form) — is pretty-printed with syntax
  highlighting via `Core.json`.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core

  attr :entry, :map, required: true
  attr :show_step, :boolean, default: true

  def row(assigns) do
    entry = assigns.entry
    level = to_string(entry["level"] || "")

    assigns =
      assign(assigns,
        level: level,
        tint: row_tint(level),
        labels: meta_labels(entry),
        parsed: parse_message(entry["message"]),
        rest_fields: rest_fields(entry)
      )

    ~H"""
    <details class={["group/row border-l-2", @tint]}>
      <summary class={[
        "flex cursor-pointer items-baseline gap-3 px-3 py-[3px] font-mono text-[11px] leading-relaxed",
        "list-none hover:bg-accent/30 [&::-webkit-details-marker]:hidden"
      ]}>
        <Core.local_time
          at={@entry["timestamp"]}
          format="time"
          class="shrink-0 whitespace-nowrap tabular-nums text-muted-foreground/70"
        />
        <span class={["w-12 shrink-0 font-semibold uppercase", level_class(@level)]}>{@entry["level"] || "—"}</span>
        <span
          :if={@show_step}
          class="hidden shrink-0 truncate text-muted-foreground/55 md:inline md:max-w-[150px]"
        >{@entry["__step__"]}</span>
        <span class="min-w-0 flex-1 break-words text-foreground/90">{inline_message(@parsed, @entry["message"])}</span>
        <span :if={@labels != ""} class="hidden shrink-0 whitespace-nowrap text-[10px] text-muted-foreground/45 group-open/row:hidden lg:inline">{@labels}</span>
        <Core.icon
          name="chevron-down"
          class="size-3 shrink-0 self-center text-muted-foreground/40 transition-transform group-open/row:rotate-180"
        />
      </summary>

      <div class="space-y-3 border-t border-border/50 bg-muted/20 px-4 py-3">
        <div class="space-y-1.5">
          <Core.label>message</Core.label>
          <%= case @parsed do %>
            <% {:term, term} -> %>
              <Core.json value={term} class="max-h-[40vh]" />
            <% {:prefix_term, prefix, term} -> %>
              <p :if={prefix != ""} class="break-words font-mono text-[11px] text-foreground/70">{prefix}</p>
              <Core.json value={term} class="max-h-[40vh]" />
            <% :text -> %>
              <div class="break-words whitespace-pre-wrap font-mono text-[11px] text-foreground/90">{@entry["message"]}</div>
          <% end %>
        </div>

        <Core.field_list class="border-t border-border/40 pt-3">
          <Core.field :if={@entry["timestamp"]} key="time">
            <Core.local_time at={@entry["timestamp"]} format="datetime" />
          </Core.field>
          <Core.field :for={{k, v} <- @rest_fields} key={k}>{v}</Core.field>
        </Core.field_list>
      </div>
    </details>
    """
  end

  # ============================================================================
  # Level styling
  # ============================================================================

  def level_class("error"), do: "text-destructive"
  def level_class("warning"), do: "text-warning"
  def level_class("info"), do: "text-info"
  def level_class("debug"), do: "text-muted-foreground"
  def level_class(_), do: "text-muted-foreground"

  # Per-level left-bar accent + faint row tint so error/warning stand out.
  defp row_tint("error"), do: "border-l-destructive bg-destructive/5"
  defp row_tint("warning"), do: "border-l-warning bg-warning/5"
  defp row_tint("info"), do: "border-l-info/50"
  defp row_tint("debug"), do: "border-l-border"
  defp row_tint(_), do: "border-l-transparent"

  # ============================================================================
  # Inline metadata labels
  # ============================================================================

  # Meaningful metadata as a compact inline `key=value` string. Framework /
  # source-location internals are filtered so the lines stay clean.
  @noise_meta ~w(line module function file pid mfa domain gl time application erl_level
                 otel_span_id otel_trace_id ansi_color)
  def meta_labels(entry) do
    case entry["metadata"] do
      m when is_map(m) and map_size(m) > 0 ->
        m
        |> Enum.reject(fn {k, _} -> to_string(k) in @noise_meta end)
        |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inline_value(v)}" end)

      _ ->
        ""
    end
  end

  defp inline_value(v) when is_binary(v) or is_number(v) or is_atom(v) do
    s = to_string(v)
    if String.length(s) > 40, do: String.slice(s, 0, 39) <> "…", else: s
  end

  defp inline_value(v), do: v |> inspect() |> inline_value()

  # ============================================================================
  # Expanded fields table
  # ============================================================================

  # Non-message fields: core fields followed by every metadata key (source
  # noise included — it's fine in a deliberate detail view). The message and
  # the (localized) time render separately; everything else lands here.
  def rest_fields(entry) do
    base = [
      {"level", to_string(entry["level"])},
      {"step", entry["__step__"]},
      {"source", entry["source"]}
    ]

    meta =
      case entry["metadata"] do
        m when is_map(m) -> Enum.map(m, fn {k, v} -> {to_string(k), detail_value(v)} end)
        _ -> []
      end

    Enum.reject(base ++ meta, fn {_k, v} -> v in [nil, ""] end)
  end

  defp detail_value(v) when is_binary(v), do: v
  defp detail_value(v) when is_number(v) or is_atom(v), do: to_string(v)
  defp detail_value(v), do: inspect(v)

  # ============================================================================
  # Message parsing — JSON or embedded Elixir term, highlighted via Core.json
  # ============================================================================

  @doc """
  Classify a log message for rendering:

    * `{:term, term}` — the whole message is a JSON value or Elixir literal
    * `{:prefix_term, prefix, term}` — a text prefix followed by a `%{...}`
      Elixir map (the `"label: \#{inspect(map)}"` shape)
    * `:text` — plain text, render raw

  """
  def parse_message(msg) when is_binary(msg) do
    trimmed = String.trim(msg)

    cond do
      term = whole_term(trimmed) -> {:term, term}
      true -> prefix_term(msg)
    end
  end

  def parse_message(_), do: :text

  # The inline (collapsed) one-liner: raw text for plain messages; a compact,
  # whitespace-collapsed one-liner for structured ones (full pretty form lives
  # in the expanded block).
  defp inline_message(:text, msg), do: msg
  defp inline_message(_structured, msg), do: truncate_inline(to_string(msg))

  defp whole_term(trimmed) do
    cond do
      String.starts_with?(trimmed, ["{", "["]) -> json_term(trimmed)
      String.starts_with?(trimmed, "%{") -> elixir_term(trimmed)
      true -> nil
    end
  end

  defp json_term(s) do
    case Jason.decode(s) do
      {:ok, t} when is_map(t) or is_list(t) -> t
      _ -> nil
    end
  end

  defp elixir_term(s) do
    case safe_literal(s) do
      {:ok, t} -> t
      :error -> nil
    end
  end

  # A "label: %{...}" message — text prefix + trailing Elixir map. Split on the
  # first `%{` only (so a leading `[tag]` in the prefix is never mistaken for a
  # list literal); fall back to plain text if the tail isn't a clean literal.
  defp prefix_term(msg) do
    case String.split(msg, "%{", parts: 2) do
      [prefix, rest] when prefix != "" ->
        case safe_literal("%{" <> rest) do
          {:ok, term} -> {:prefix_term, String.trim(prefix), term}
          :error -> :text
        end

      _ ->
        :text
    end
  end

  # Parse a string to AST (no evaluation) and rebuild it as a plain value ONLY
  # if every node is a literal (map/list/number/string/atom/bool/nil). Anything
  # else — a function call, tuple, struct, interpolation — fails the whole
  # parse and we fall back to rendering the raw text. Safe: code is never run.
  defp safe_literal(str) do
    case Code.string_to_quoted(str) do
      {:ok, ast} -> eval_literal(ast)
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp eval_literal(n)
       when is_number(n) or is_binary(n) or is_boolean(n) or is_nil(n) or is_atom(n),
       do: {:ok, n}

  defp eval_literal({:-, _, [n]}) when is_number(n), do: {:ok, -n}

  defp eval_literal({:%{}, _, pairs}) when is_list(pairs), do: build_map(pairs)

  defp eval_literal(list) when is_list(list), do: build_list(list)

  defp eval_literal(_), do: :error

  defp build_map(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {k_ast, v_ast}, {:ok, acc} ->
        with {:ok, k} <- eval_literal(k_ast),
             {:ok, v} <- eval_literal(v_ast) do
          {:cont, {:ok, Map.put(acc, k, v)}}
        else
          _ -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp build_list(elems) do
    elems
    |> Enum.reduce_while({:ok, []}, fn el, {:ok, acc} ->
      case eval_literal(el) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      :error -> :error
    end
  end

  defp truncate_inline(s) when is_binary(s) do
    collapsed = s |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(collapsed) > 160, do: String.slice(collapsed, 0, 159) <> "…", else: collapsed
  end
end
