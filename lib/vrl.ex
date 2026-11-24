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
  Other structs are passed as maps, keeping `"__struct__"` unless the
  `:strip_structs` option is set.
  """

  alias VRL.{Program, Result}

  @type event :: term()
  @type run_error :: String.t() | {:abort, String.t()}

  @max_depth 128
  @default_timeout 5_000

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
  calls `abort`, and `{:error, :timeout}` when it exceeds the timeout.

  ## Options

    * `:timeout` - maximum run time in milliseconds, or `:infinity`.
      Defaults to `5000`. Checked between VRL expressions, so a single
      long-running function call can overrun it.
    * `:strip_structs` - when `true`, structs other than `DateTime` are
      passed as plain maps without the `"__struct__"` key. Defaults to `false`.
  """
  @spec run(Program.t(), event(), keyword()) ::
          {:ok, Result.t()} | {:error, run_error() | :timeout}
  def run(%Program{ref: ref}, event \\ %{}, opts \\ []) do
    timeout =
      case Keyword.get(opts, :timeout, @default_timeout) do
        :infinity ->
          nil

        ms when is_integer(ms) and ms >= 0 ->
          ms

        other ->
          raise ArgumentError,
                "expected :timeout to be a non-negative integer or :infinity, got: #{inspect(other)}"
      end

    with {:ok, value, event} <-
           VRL.Native.run(ref, event, timeout, Keyword.get(opts, :strip_structs, false) == true) do
      {:ok, %Result{value: value, event: event}}
    end
  end
end
