defmodule VRL.Result do
  @moduledoc """
  The outcome of a successful `VRL.run/3`.

    * `:value` - the result of the program's last expression
    * `:event` - the event after the program's modifications
    * `:metadata` - the metadata (`%`) after the program's modifications
  """

  @enforce_keys [:value, :event, :metadata]
  defstruct [:value, :event, :metadata]

  @type t :: %__MODULE__{value: term(), event: term(), metadata: map()}
end
