defmodule Durable.Executor.Backoff do
  @moduledoc """
  Backoff strategies for step retry logic.

  Supports three backoff strategies:
  - `:exponential` - Delay grows exponentially (2^attempt * base)
  - `:linear` - Delay grows linearly (attempt * base)
  - `:constant` - Fixed delay between retries

  All delays are in milliseconds and capped at a configurable maximum.
  """

  @type strategy :: :exponential | :linear | :constant

  @type opts :: %{
          optional(:base) => pos_integer(),
          optional(:max_backoff) => pos_integer()
        }

  @default_base 1_000
  @default_max_backoff 3_600_000

  @doc """
  Calculates the delay before the next retry attempt.

  ## Arguments

  - `strategy` - The backoff strategy to use
  - `attempt` - The current attempt number (1-based)
  - `opts` - Options for the backoff calculation

  ## Options

  - `:base` - Base delay in milliseconds (default: 1000)
  - `:max_backoff` - Maximum delay in milliseconds (default: 3600000 = 1 hour)

  ## Examples

      iex> Backoff.calculate(:exponential, 1, %{base: 1000})
      2000

      iex> Backoff.calculate(:exponential, 3, %{base: 1000})
      8000

      iex> Backoff.calculate(:linear, 3, %{base: 1000})
      3000

      iex> Backoff.calculate(:constant, 5, %{base: 1000})
      1000

  """
  @spec calculate(strategy(), pos_integer(), opts()) :: pos_integer()
  def calculate(strategy, attempt, opts \\ %{})

  def calculate(:exponential, attempt, opts) do
    base = Map.get(opts, :base, @default_base)
    max = Map.get(opts, :max_backoff, @default_max_backoff)

    delay = trunc(:math.pow(2, attempt) * base)
    min(delay, max)
  end

  def calculate(:linear, attempt, opts) do
    base = Map.get(opts, :base, @default_base)
    max = Map.get(opts, :max_backoff, @default_max_backoff)

    delay = attempt * base
    min(delay, max)
  end

  def calculate(:constant, _attempt, opts) do
    Map.get(opts, :base, @default_base)
  end

  @doc """
  Calculates delay with jitter to avoid thundering herd.

  Adds random jitter of ±25% to the calculated delay.

  ## Examples

      # Delay will be between 1500 and 2500 for exponential with attempt=1
      Backoff.calculate_with_jitter(:exponential, 1, %{base: 1000})

  """
  @spec calculate_with_jitter(strategy(), pos_integer(), opts()) :: pos_integer()
  def calculate_with_jitter(strategy, attempt, opts \\ %{}) do
    base_delay = calculate(strategy, attempt, opts)
    jitter_factor = 0.25
    jitter_range = trunc(base_delay * jitter_factor)

    # Add random jitter between -jitter_range and +jitter_range
    jitter = :rand.uniform(jitter_range * 2) - jitter_range
    max(0, base_delay + jitter)
  end

  @doc """
  Sleeps for the calculated backoff duration.

  ## Examples

      Backoff.sleep(:exponential, 2, %{base: 1000})

  """
  @spec sleep(strategy(), pos_integer(), opts()) :: :ok
  def sleep(strategy, attempt, opts \\ %{}) do
    delay = calculate_with_jitter(strategy, attempt, opts)
    Process.sleep(delay)
    :ok
  end
end
