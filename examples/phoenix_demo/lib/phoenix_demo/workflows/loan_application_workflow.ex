defmodule PhoenixDemo.Workflows.LoanApplicationWorkflow do
  @moduledoc """
  A loan application, scored from three lookups that run at once. The credit
  report is required and retried; the device check may fail, and the decision
  takes "unknown" trust instead; the social lookup is a lane of two steps with
  a time limit, and the decision goes on without it if it runs long. An
  underwriter then signs off, and the loan is paid out. Rolled back, the
  application is withdrawn.

  Showcases: named `parallel` lanes with `optional:`, `default:` and
  `timeout:`, step `retry:` and `compensate:`, and `wait_for_approval`.

  Input:
      %{"applicant" => "Dana", "amount" => 12000, "device_check" => "up"}
  """

  use Durable
  use Durable.Helpers
  use Durable.Wait

  require Logger

  workflow "loan_application", timeout: days(3) do
    step :open_application, [compensate: :withdraw_application], fn application ->
      id = "LN-#{:rand.uniform(99_999)}"
      Logger.info("[Loan] Opened #{id} for #{application["applicant"]}")
      {:ok, assign(application, :application_id, id)}
    end

    parallel :lookups do
      step :credit_report, [retry: [max_attempts: 3, backoff: :exponential]], fn application ->
        Process.sleep(200 + :rand.uniform(400))
        {:ok, assign(application, :score, 640 + :rand.uniform(160))}
      end

      step :device_check, [optional: true, default: %{trust: "unknown"}], fn application ->
        if application["device_check"] == "down",
          do: {:fail, "the device service is down"},
          else: {:ok, assign(application, :trust, "high")}
      end

      lane :social, optional: true, default: %{profiles: 0}, timeout: seconds(5) do
        step :find_profiles, fn application ->
          Process.sleep(300 + :rand.uniform(700))
          {:ok, assign(application, :profiles, 2)}
        end

        step :rate_profiles, fn application ->
          {:ok, assign(application, :profiles_rating, "consistent")}
        end
      end
    end

    step :decide, fn %{"lookups" => lookups} = application ->
      score = get(lookups, ["credit_report", "score"]) || 0
      decision = if score >= 700, do: "approve", else: "refer"
      {:ok, assign(application, :decision, decision)}
    end

    step :underwriter_sign_off, fn application ->
      wait_for_approval("underwriter_sign_off",
        prompt:
          "Sign off loan #{application["application_id"]} of $#{application["amount"]} " <>
            "for #{application["applicant"]} (#{application["decision"]})?",
        timeout: days(2)
      )

      {:ok, application}
    end

    step :disburse, fn application ->
      Logger.info("[Loan] Paid out #{application["application_id"]}")
      {:ok, assign(application, :disbursed, true)}
    end

    compensate :withdraw_application, fn application ->
      Logger.info("[Loan] Withdrew #{application["application_id"]}")
      {:ok, application}
    end
  end
end
