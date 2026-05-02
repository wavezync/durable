defmodule Durable.TestWorkflows.SimpleWorkflow do
  @moduledoc false
  use Durable

  workflow "simple" do
    step(:hello, fn _data ->
      {:ok, %{message: "hello"}}
    end)
  end
end
