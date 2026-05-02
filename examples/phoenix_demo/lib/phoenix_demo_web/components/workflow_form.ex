defmodule PhoenixDemoWeb.WorkflowForm do
  @moduledoc """
  Renders a dynamic form from a list of field specs. Used by HomeLive
  (workflow trigger modal) and PendingInputsLive (form/text/choice/approval
  responses).

  A field spec is a map with the keys (string or atom):
    - `name` (required) — form field name
    - `label`            — visible label
    - `type`             — "text" | "number" | "select" | "checkbox" | "textarea" | "radio"
    - `options`          — list of strings or %{value, label} maps (for select/radio)
    - `default`          — initial value
    - `required`         — bool

  Submit emits a `phx-submit={event}` with `phx-value-key={key}` (when set).
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :fields, :list, required: true
  attr :submit_label, :string, default: "Submit"
  attr :submit_event, :string, required: true
  attr :submit_key, :string, default: nil
  attr :extra_hidden, :map, default: %{}

  def dynamic_form(assigns) do
    ~H"""
    <form
      id={@id}
      phx-submit={@submit_event}
      class="space-y-3"
    >
      <input :if={@submit_key} type="hidden" name="key" value={@submit_key} />
      <input
        :for={{k, v} <- @extra_hidden}
        type="hidden"
        name={"hidden[#{k}]"}
        value={v}
      />

      <div :for={field <- @fields} class="form-control w-full">
        <.field_input field={field} />
      </div>

      <div class="flex justify-end pt-2">
        <button type="submit" class="btn btn-primary btn-sm">
          {@submit_label}
        </button>
      </div>
    </form>
    """
  end

  attr :field, :map, required: true

  defp field_input(%{field: field} = assigns) do
    name = sget(field, "name")
    label = sget(field, "label") || humanize(name)
    type = sget(field, "type") || "text"
    default = sget(field, "default")
    required = sget(field, "required") == true
    options = sget(field, "options") || []

    assigns =
      assign(assigns,
        name: name,
        label: label,
        type: type,
        default: default,
        required: required,
        options: options
      )

    ~H"""
    <label class="label flex flex-col items-start gap-1">
      <span class="label-text text-sm">
        {@label}
        <span :if={@required} class="text-error">*</span>
      </span>

      <%= case @type do %>
        <% "select" -> %>
          <select
            name={"fields[#{@name}]"}
            class="select select-bordered select-sm w-full"
            required={@required}
          >
            <option value="">— Select —</option>
            <option :for={opt <- @options} value={option_value(opt)} selected={option_value(opt) == to_string(@default)}>
              {option_label(opt)}
            </option>
          </select>
        <% "radio" -> %>
          <div class="flex flex-col gap-1">
            <label :for={opt <- @options} class="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name={"fields[#{@name}]"}
                value={option_value(opt)}
                class="radio radio-sm radio-primary"
                checked={option_value(opt) == to_string(@default)}
                required={@required}
              />
              <span class="text-sm">{option_label(opt)}</span>
            </label>
          </div>
        <% "checkbox" -> %>
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              name={"fields[#{@name}]"}
              value="true"
              class="checkbox checkbox-sm checkbox-primary"
              checked={@default == true}
            />
            <span class="text-xs text-base-content/70">{sget(@field, "hint") || ""}</span>
          </label>
        <% "textarea" -> %>
          <textarea
            name={"fields[#{@name}]"}
            class="textarea textarea-bordered textarea-sm w-full"
            rows="3"
            required={@required}
          >{@default}</textarea>
        <% "number" -> %>
          <input
            type="number"
            name={"fields[#{@name}]"}
            value={@default}
            class="input input-bordered input-sm w-full"
            required={@required}
            step="any"
          />
        <% _ -> %>
          <input
            type="text"
            name={"fields[#{@name}]"}
            value={@default}
            class="input input-bordered input-sm w-full"
            required={@required}
          />
      <% end %>
    </label>
    """
  end

  defp option_value(%{value: v}), do: to_string(v)
  defp option_value(%{"value" => v}), do: to_string(v)
  defp option_value(s) when is_binary(s), do: s
  defp option_value(s) when is_atom(s), do: Atom.to_string(s)

  defp option_label(%{label: l}), do: l
  defp option_label(%{"label" => l}), do: l
  defp option_label(s) when is_binary(s), do: s
  defp option_label(s) when is_atom(s), do: Atom.to_string(s)

  defp sget(map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp humanize(nil), do: ""
  defp humanize(name), do: name |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
