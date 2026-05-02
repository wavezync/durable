defmodule PhoenixDemo.Workflows.ExpenseApprovalWorkflow do
  @moduledoc """
  Collects an expense report through a form, then routes for one or two
  approvals depending on the dollar amount. Expenses ≤ $1,000 need a single
  manager sign-off; expenses > $1,000 require manager AND CFO approval in
  parallel via `wait_for_all`.

  Showcases: `wait_for_form`, `wait_for_all`, `wait_for_approval`,
  `decision`-style branching.

  Input: `%{"employee" => "Alice"}`
  """

  use Durable
  use Durable.Helpers
  use Durable.Context
  use Durable.Wait

  require Logger

  @dual_approval_threshold 1_000

  workflow "expense_approval", timeout: hours(48) do
    step :collect_expense, fn data ->
      employee = data["employee"] || "Anonymous"
      put_context(:employee, employee)

      Logger.info("[Expense] Collecting expense from #{employee}")

      result =
        wait_for_form("expense_details",
          prompt: "Submit expense for #{employee}",
          fields: [
            %{name: "amount", type: "number", label: "Amount ($)", required: true},
            %{
              name: "category",
              type: "select",
              label: "Category",
              options: ["Travel", "Meals", "Equipment", "Software", "Other"],
              required: true
            },
            %{name: "description", type: "text", label: "Description", required: true}
          ],
          timeout: hours(24)
        )

      amount =
        case result["amount"] do
          n when is_number(n) -> n
          s when is_binary(s) -> case Float.parse(s) do
            {n, _} -> n
            :error -> 0
          end
          _ -> 0
        end

      put_context(:amount, amount)
      put_context(:category, result["category"])
      put_context(:description, result["description"])

      Logger.info("[Expense] Received: $#{amount} #{result["category"]} — #{result["description"]}")

      {:ok, assign(data, :expense, %{"amount" => amount, "category" => result["category"], "description" => result["description"]})}
    end

    decision :route_by_amount, fn data ->
      amount = get_context(:amount) || 0

      if amount > @dual_approval_threshold do
        Logger.info("[Expense] $#{amount} > threshold — routing to dual approval")
        put_context(:approval_path, "dual")
        {:ok, data}
      else
        Logger.info("[Expense] $#{amount} ≤ threshold — single approval")
        put_context(:approval_path, "single")
        {:goto, :single_approval, data}
      end
    end

    step :dual_approval, fn data ->
      employee = get_context(:employee)
      amount = get_context(:amount)

      Logger.info("[Expense] Awaiting parallel manager+CFO approval for $#{amount}")

      results =
        wait_for_all(
          ["manager_approval", "cfo_approval"],
          timeout: hours(48)
        )

      put_context(:approvals, results)

      manager_ok = approved?(results["manager_approval"])
      cfo_ok = approved?(results["cfo_approval"])

      if manager_ok and cfo_ok do
        Logger.info("[Expense] Manager + CFO both approved $#{amount} for #{employee}")
        {:ok, assign(data, :approved, true)}
      else
        Logger.warning("[Expense] Approval denied — manager=#{manager_ok} cfo=#{cfo_ok}")
        {:ok, assign(data, :approved, false)}
      end
    end

    step :single_approval, fn data ->
      employee = get_context(:employee)
      amount = get_context(:amount)
      category = get_context(:category)

      Logger.info("[Expense] Awaiting manager approval for $#{amount}")

      result =
        wait_for_approval("manager_approval",
          prompt: "Approve $#{amount} #{category} expense from #{employee}?",
          metadata: %{
            "employee" => employee,
            "amount" => amount,
            "category" => category,
            "description" => get_context(:description)
          },
          timeout: hours(24)
        )

      approved = approved?(result)
      put_context(:single_approval_result, result)

      Logger.info("[Expense] Single approval result: #{approved}")
      {:ok, assign(data, :approved, approved)}
    end

    step :record_expense, fn data ->
      employee = get_context(:employee)
      amount = get_context(:amount)
      category = get_context(:category)
      approved = data[:approved] == true
      path = get_context(:approval_path)

      status = if approved, do: "recorded", else: "denied"
      Logger.info("[Expense] $#{amount} #{category} for #{employee} — #{status} (#{path} approval)")

      {:ok,
       %{
         "employee" => employee,
         "amount" => amount,
         "category" => category,
         "approval_path" => path,
         "status" => status,
         "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  defp approved?(:approved), do: true
  defp approved?("approved"), do: true
  defp approved?(%{"approved" => true}), do: true
  defp approved?(%{"value" => true}), do: true
  defp approved?(%{"value" => :approved}), do: true
  defp approved?(_), do: false
end
