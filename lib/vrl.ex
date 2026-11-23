defmodule VRL do
  @moduledoc """
  Elixir bindings for [Vector Remap Language](https://vrl.dev).

  Compile a program once with `compile/1`, then run it against many events
  with `run/2`. The full VRL standard library is available, except for
  network functions.

      iex> {:ok, program} = VRL.compile(".message = upcase!(.message)")
      iex> VRL.run(program, %{"message" => "hello"})
      {:ok, %VRL.Result{value: "HELLO", event: %{"message" => "HELLO"}}}

  ## Value conversion

  | Elixir                   | VRL       |
  | ------------------------ | --------- |
  | binary                   | string    |
  | integer (64-bit)         | integer   |
  | float                    | float     |
  | `true` / `false`         | boolean   |
  | `nil`                    | null      |
  | map                      | object    |
  | list                     | array     |
  | `DateTime`               | timestamp |
  | other atoms              | string    |

  Map keys may be binaries or atoms; returned maps always have binary keys.
  Timestamps are returned as UTC `DateTime`s with microsecond precision.
  """

  alias VRL.{Program, Result}

  @type event :: term()
  @type run_error :: String.t() | {:abort, String.t()}

  @max_depth 128

  @doc """
  Maximum nesting of maps and lists accepted by and returned from `run/2`.

  Deeper values return `{:error, "maximum nesting depth of 128 exceeded"}`.
  """
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Compiles VRL `source` into a reusable `VRL.Program`.

  Returns `{:error, diagnostics}` with human-readable diagnostics when the
  program is invalid.
  """
  @spec compile(String.t()) :: {:ok, Program.t()} | {:error, String.t()}
  def compile(source) when is_binary(source) do
    with {:ok, ref} <- VRL.Native.compile(source) do
      {:ok, %Program{source: source, ref: ref}}
    end
  end

  @doc """
  Runs a compiled `program` against `event`.

  Returns `{:ok, %VRL.Result{}}` with the program's resulting value and the
  transformed event. Returns `{:error, {:abort, message}}` when the program
  calls `abort`.
  """
  @spec run(Program.t(), event()) :: {:ok, Result.t()} | {:error, run_error()}
  def run(%Program{ref: ref}, event \\ %{}) do
    with {:ok, value, event} <- VRL.Native.run(ref, event) do
      {:ok, %Result{value: value, event: event}}
    end
  end
end
