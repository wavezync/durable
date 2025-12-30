defmodule Durable.Definition do
  @moduledoc """
  Structs representing workflow and step definitions.

  These structs are generated at compile time from the DSL macros
  and used by the executor at runtime.
  """

  defmodule Step do
    @moduledoc """
    Represents a single step in a workflow.

    The `body_fn` field contains a 0-arity function that returns the step body function.
    This indirection allows the step definition to be stored at compile time while
    the actual step logic is compiled into the module.
    """

    @type step_type :: :step | :decision | :parallel | :loop | :foreach | :switch

    @type retry_opts :: %{
            optional(:max_attempts) => pos_integer(),
            optional(:backoff) => :exponential | :linear | :constant,
            optional(:base) => pos_integer(),
            optional(:max_backoff) => pos_integer()
          }

    @type t :: %__MODULE__{
            name: atom(),
            type: step_type(),
            module: module(),
            opts: %{
              optional(:retry) => retry_opts(),
              optional(:timeout) => pos_integer(),
              optional(:compensate) => atom(),
              optional(:queue) => atom()
            }
          }

    @enforce_keys [:name, :type, :module]
    defstruct [
      :name,
      :type,
      :module,
      opts: %{}
    ]

    @doc """
    Executes the step body by calling the generated function in the module.
    """
    def execute(%__MODULE__{name: name, module: module}, context) do
      apply(module, :"__step_body__#{name}", [context])
    end
  end

  defmodule Workflow do
    @moduledoc """
    Represents a complete workflow definition.
    """

    @type t :: %__MODULE__{
            name: String.t(),
            module: module(),
            steps: [Step.t()],
            opts: %{
              optional(:timeout) => pos_integer(),
              optional(:max_retries) => pos_integer(),
              optional(:queue) => atom()
            }
          }

    @enforce_keys [:name, :module, :steps]
    defstruct [
      :name,
      :module,
      steps: [],
      opts: %{}
    ]
  end
end
