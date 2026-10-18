defmodule DurableDashboard.Cron do
  @moduledoc """
  Says a cron expression in words — "Every day at 09:00", "Weekdays at
  17:30", "Every 15 minutes" — for the common shapes. Anything it doesn't
  recognise returns nil, and the page shows the expression as written.
  """

  @days ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

  @aliases %{
    "@yearly" => "0 0 1 1 *",
    "@annually" => "0 0 1 1 *",
    "@monthly" => "0 0 1 * *",
    "@weekly" => "0 0 * * 0",
    "@daily" => "0 0 * * *",
    "@midnight" => "0 0 * * *",
    "@hourly" => "0 * * * *"
  }

  @spec describe(String.t() | nil) :: String.t() | nil
  def describe(nil), do: nil

  def describe(expression) do
    expression = String.trim(expression)

    case String.split(Map.get(@aliases, expression, expression)) do
      [m, h, dom, mon, dow] -> fields(m, h, dom, mon, dow)
      _ -> nil
    end
  end

  defp fields("*", "*", "*", "*", "*"), do: "Every minute"
  defp fields("*/" <> n, "*", "*", "*", "*"), do: every(n, "minute")

  defp fields(m, "*", "*", "*", "*") do
    with {:ok, minute} <- number(m, 0..59), do: "Every hour at :#{pad(minute)}"
  end

  defp fields(m, "*/" <> n, "*", "*", "*") do
    with {:ok, minute} <- number(m, 0..59),
         {:ok, hours} <- number(n, 1..23),
         do: "Every #{hours} hours at :#{pad(minute)}"
  end

  defp fields(m, h, "*", "*", dow) do
    with {:ok, times} <- times(m, h), {:ok, days} <- days(dow), do: "#{days} at #{times}"
  end

  defp fields(m, h, dom, "*", "*") do
    with {:ok, times} <- times(m, h),
         {:ok, day} <- number(dom, 1..31),
         do: "Monthly on day #{day} at #{times}"
  end

  defp fields(_m, _h, _dom, _mon, _dow), do: nil

  defp every(n, unit) do
    case number(n, 1..59) do
      {:ok, 1} -> "Every #{unit}"
      {:ok, k} -> "Every #{k} #{unit}s"
      _ -> nil
    end
  end

  # "0 9,17" -> "09:00 and 17:00"
  defp times(m, h) do
    with {:ok, minute} <- number(m, 0..59),
         {:ok, hours} <- list(h, 0..23) do
      {:ok, hours |> Enum.map(&"#{pad(&1)}:#{pad(minute)}") |> join()}
    end
  end

  defp days("*"), do: {:ok, "Every day"}
  defp days("1-5"), do: {:ok, "Weekdays"}

  defp days(dow) when dow in ["0,6", "6,0", "6-7", "6,7"], do: {:ok, "Weekends"}

  defp days(dow) do
    with {:ok, days} <- list(dow, 0..7) do
      {:ok, "Every " <> (days |> Enum.map(&Enum.at(@days, rem(&1, 7))) |> join())}
    end
  end

  defp list(text, range) do
    text
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case number(part, range) do
        {:ok, n} -> {:cont, {:ok, acc ++ [n]}}
        _ -> {:halt, nil}
      end
    end)
  end

  defp number(text, range) do
    case Integer.parse(text) do
      {n, ""} -> if n in range, do: {:ok, n}
      _ -> nil
    end
  end

  defp join([one]), do: one
  defp join(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " and " <> List.last(items)

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
