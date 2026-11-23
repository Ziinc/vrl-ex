defmodule VRL.Result do
  @moduledoc """
  The outcome of a successful `VRL.run/2`.

    * `:value` - the result of the program's last expression
    * `:event` - the event after the program's modifications
  """

  @enforce_keys [:value, :event]
  defstruct [:value, :event]

  @type t :: %__MODULE__{value: term(), event: term()}
end
