defmodule VRL do
  @moduledoc """
  Elixir bindings for [Vector Remap Language](https://vrl.dev).

  Compile a program once with `compile/2`, then run it against many events
  with `run/3`. The full VRL standard library is available, except for
  network functions.

      iex> {:ok, program} = VRL.compile(".message = upcase!(.message)")
      iex> VRL.run(program, %{"message" => "hello"})
      {:ok, %VRL.Result{value: "HELLO", event: %{"message" => "HELLO"}, metadata: %{}}}

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

  ## Integer overflow

  VRL integer arithmetic (`+`, `-`, `*`) wraps around on 64-bit overflow
  without an error or warning. This is upstream VRL behaviour:

      iex> {:ok, program} = VRL.compile("9223372036854775807 + 1")
      iex> {:ok, %VRL.Result{value: value}} = VRL.run(program)
      iex> value
      -9223372036854775808
  """

  alias VRL.{Program, Result}

  @type event :: term()
  @type run_error :: String.t() | {:abort, String.t()}

  @max_depth 128
  @default_timeout 5_000

  @doc """
  Maximum nesting of maps and lists accepted by and returned from `run/3`.

  Deeper values return `{:error, "maximum nesting depth of 128 exceeded"}`.
  """
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Compiles VRL `source` into a reusable `VRL.Program`.

  Returns `{:error, diagnostics}` with human-readable diagnostics when the
  program is invalid.

  ## Options

    * `:deny_functions` - names of standard library functions the program may
      not call. Functions that read the host are `get_env_var`, `get_hostname`,
      `get_timezone_name`, `encode_proto`, `parse_proto`, `parse_etld` and
      `validate_json_schema`; deny them for untrusted programs.
  """
  @spec compile(String.t(), keyword()) :: {:ok, Program.t()} | {:error, String.t()}
  def compile(source, opts \\ []) when is_binary(source) do
    opts = Keyword.validate!(opts, deny_functions: [])

    with {:ok, ref} <- VRL.Native.compile(source, Enum.map(opts[:deny_functions], &to_string/1)) do
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
    * `:metadata` - map exposed to the program as `%`. Defaults to `%{}`.
    * `:strip_structs` - when `true`, structs other than `DateTime` are
      passed as plain maps without the `"__struct__"` key. Defaults to `false`.
  """
  @spec run(Program.t(), event(), keyword()) ::
          {:ok, Result.t()} | {:error, run_error() | :timeout}
  def run(%Program{ref: ref}, event \\ %{}, opts \\ []) do
    opts = Keyword.validate!(opts, timeout: @default_timeout, metadata: %{}, strip_structs: false)
    metadata = opts[:metadata]

    unless is_map(metadata) and not is_struct(metadata) do
      raise ArgumentError, "expected :metadata to be a map, got: #{inspect(metadata)}"
    end

    with {:ok, value, event, metadata} <-
           VRL.Native.run(
             ref,
             event,
             timeout_ms(opts[:timeout]),
             metadata,
             opts[:strip_structs] == true
           ) do
      {:ok, %Result{value: value, event: event, metadata: metadata}}
    end
  end

  @doc """
  Runs `program` over a batch of JSON `documents` in one native call, parsing
  and writing JSON in Rust. Prefer it over `run/3` for throughput.

  Returns, per document, `{:ok, json, event_bytes}` with the new document and
  the byte length of its event JSON, `:abort`, `{:error, :timeout}` or
  `{:error, message}`.

  ## Options

    * `:event` - top-level key holding the event. Other keys are copied
      verbatim, in order. Defaults to `nil`: the whole document is the event.
    * `:metadata` - top-level keys exposed as `%key` (requires `:event`) and
      written back if present in the document; `{key, :read_only}` is not
      written back. Defaults to `[]`.
    * `:timeout` - as in `run/3`, per document.
  """
  @spec run_json(Program.t(), [binary()], keyword()) ::
          [{:ok, binary(), non_neg_integer()} | :abort | {:error, :timeout | String.t()}]
  def run_json(%Program{ref: ref}, documents, opts \\ []) when is_list(documents) do
    opts = Keyword.validate!(opts, timeout: @default_timeout, event: nil, metadata: [])

    if opts[:metadata] != [] and is_nil(opts[:event]) do
      raise ArgumentError, ":metadata requires :event"
    end

    metadata =
      Enum.map(opts[:metadata], fn
        {key, :read_only} -> {to_string(key), false}
        key -> {to_string(key), true}
      end)

    event = if opts[:event], do: to_string(opts[:event])
    VRL.Native.run_json(ref, documents, event, metadata, timeout_ms(opts[:timeout]))
  end

  defp timeout_ms(:infinity), do: nil
  defp timeout_ms(ms) when is_integer(ms) and ms >= 0, do: ms

  defp timeout_ms(other) do
    raise ArgumentError,
          "expected :timeout to be a non-negative integer or :infinity, got: #{inspect(other)}"
  end
end
