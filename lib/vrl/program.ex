defmodule VRL.Program do
  @moduledoc """
  A compiled VRL program, returned by `VRL.compile/1`.

  Programs are immutable and safe to share across processes.
  """

  @enforce_keys [:source, :ref]
  defstruct [:source, :ref]

  @type t :: %__MODULE__{source: String.t(), ref: reference()}

  defimpl Inspect do
    def inspect(%{source: source}, _opts), do: "#VRL.Program<#{inspect(source)}>"
  end
end
