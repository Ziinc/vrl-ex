defmodule VRLTest do
  use ExUnit.Case, async: true
  doctest VRL

  describe "compile/2" do
    test "returns a compiled program" do
      assert {:ok, %VRL.Program{source: ".a = 1"}} = VRL.compile(".a = 1")
    end

    test "returns formatted diagnostics on compile error" do
      assert {:error, message} = VRL.compile(".a = ")
      assert message =~ "syntax error"
    end

    test "rejects unknown functions" do
      assert {:error, message} = VRL.compile("not_a_function()")
      assert message =~ "call to undefined function"
    end

    test "returns error for non-UTF8 source" do
      assert {:error, "source must be valid UTF-8"} = VRL.compile(<<255, 254>>)
    end

    test "handles deeply nested source without crashing" do
      source = String.duplicate("[", 1_000) <> "1" <> String.duplicate("]", 1_000)
      assert {status, _} = VRL.compile(source)
      assert status in [:ok, :error]
    end

    test "deny_functions rejects calls to denied functions" do
      assert {:error, message} =
               VRL.compile(~s[get_env_var!("HOME")], deny_functions: ["get_env_var"])

      assert message =~ "call to undefined function"
      assert {:ok, _} = VRL.compile(~s[upcase("a")], deny_functions: ["get_env_var"])
    end

    test "deny_functions rejects unknown function names" do
      assert {:error, "unknown function in :deny_functions: \"get_env\""} =
               VRL.compile(".", deny_functions: ["get_env"])
    end

    test "rejects invalid compile options" do
      assert_raise ArgumentError, fn -> VRL.compile(".", deny: ["log"]) end
    end

    test "requires fallible calls to be handled" do
      assert {:error, message} = VRL.compile(~s(parse_json("{}"\)))
      assert message =~ "unhandled error"
    end
  end

  describe "run/3" do
    test "returns the resolved value and the transformed event" do
      {:ok, program} = VRL.compile(~s(.b = upcase(string!(.a\)\); "done"))

      assert {:ok, %VRL.Result{value: "done", event: %{"a" => "x", "b" => "X"}}} =
               VRL.run(program, %{"a" => "x"})
    end

    test "program can be reused across runs" do
      {:ok, program} = VRL.compile(".n = int!(.n) + 1")
      assert {:ok, %VRL.Result{value: 2, event: %{"n" => 2}}} = VRL.run(program, %{"n" => 1})
      assert {:ok, %VRL.Result{value: 11, event: %{"n" => 11}}} = VRL.run(program, %{"n" => 10})
    end

    test "defaults to an empty event" do
      {:ok, program} = VRL.compile(".")
      assert {:ok, %VRL.Result{value: %{}, event: %{}}} = VRL.run(program)
    end

    test "returns runtime errors" do
      {:ok, program} = VRL.compile("parse_json!(.raw)")
      assert {:error, message} = VRL.run(program, %{"raw" => "{"})
      assert message =~ "unable to parse json"
    end

    test "returns abort with message" do
      {:ok, program} = VRL.compile(~s(abort "dropped"))
      assert {:error, {:abort, message}} = VRL.run(program, %{})
      assert message =~ "dropped"
    end
  end

  describe "run/3 :metadata" do
    test "exposes metadata to the program and returns it" do
      {:ok, program} = VRL.compile(~S|.sig = %signal; %scope.name = "x"; del(%signal)|)

      assert {:ok,
              %VRL.Result{event: %{"sig" => "logs"}, metadata: %{"scope" => %{"name" => "x"}}}} =
               VRL.run(program, %{}, metadata: %{"signal" => "logs", "scope" => %{}})
    end

    test "defaults to empty metadata" do
      {:ok, program} = VRL.compile("%")
      assert {:ok, %VRL.Result{value: %{}, metadata: %{}}} = VRL.run(program)
    end

    test "rejects non-map metadata" do
      {:ok, program} = VRL.compile(".")
      assert_raise ArgumentError, fn -> VRL.run(program, %{}, metadata: [1]) end
    end
  end

  describe "run/3 :timeout" do
    # ~100M loop iterations: runs far longer than any timeout below.
    @slow ~S"""
    r = range!(0, 10000)
    for_each(r) -> |_i, _v| { for_each(r) -> |_j, _w| { 1 } }
    """

    test "interrupts programs exceeding the timeout" do
      {:ok, program} = VRL.compile(@slow)
      {micros, result} = :timer.tc(fn -> VRL.run(program, %{}, timeout: 50) end)
      assert result == {:error, :timeout}
      assert micros < 1_000_000
    end

    test "defaults to a 5 second timeout" do
      {:ok, program} = VRL.compile(@slow)
      {micros, result} = :timer.tc(fn -> VRL.run(program) end)
      assert result == {:error, :timeout}
      assert micros in 5_000_000..6_000_000
    end

    test "timeout: 0 interrupts even short programs" do
      {:ok, program} = VRL.compile(".a = 1")
      assert VRL.run(program, %{}, timeout: 0) == {:error, :timeout}
    end

    test "completes programs within the timeout" do
      {:ok, program} = VRL.compile(".a = 1")
      assert {:ok, %VRL.Result{value: 1}} = VRL.run(program, %{}, timeout: 50)
      assert {:ok, %VRL.Result{value: 1}} = VRL.run(program, %{}, timeout: :infinity)
    end

    test "rejects invalid options" do
      {:ok, program} = VRL.compile(".")
      assert_raise ArgumentError, fn -> VRL.run(program, %{}, timeout: -1) end
      assert_raise ArgumentError, fn -> VRL.run(program, %{}, timeout: "5s") end
      assert_raise ArgumentError, fn -> VRL.run(program, %{}, timout: 5) end
    end
  end

  describe "value conversion" do
    setup do
      {:ok, program} = VRL.compile(".")
      %{identity: program}
    end

    test "converts atom keys and values to strings", %{identity: p} do
      assert {:ok, %VRL.Result{value: %{"a" => "b"}}} = VRL.run(p, %{a: :b})
    end

    test "converts DateTime to a VRL timestamp" do
      {:ok, program} = VRL.compile("is_timestamp(.t)")

      assert {:ok, %VRL.Result{value: true}} =
               VRL.run(program, %{"t" => ~U[2024-01-02 03:04:05.123456Z]})
    end

    test "shifts non-UTC DateTime to UTC", %{identity: p} do
      dt = %DateTime{
        year: 2024,
        month: 1,
        day: 2,
        hour: 11,
        minute: 4,
        second: 5,
        microsecond: {0, 0},
        utc_offset: 28_800,
        std_offset: 0,
        time_zone: "Asia/Singapore",
        zone_abbr: "+08"
      }

      assert {:ok, %VRL.Result{value: out}} = VRL.run(p, dt)
      assert out == ~U[2024-01-02 03:04:05.000000Z]
    end

    test "returns timestamps as UTC DateTime truncated to microseconds" do
      {:ok, program} = VRL.compile("t'2024-01-02T03:04:05.123456789+01:00'")
      assert {:ok, %VRL.Result{value: ~U[2024-01-02 02:04:05.123456Z]}} = VRL.run(program)
    end

    test "returns now() as DateTime" do
      {:ok, program} = VRL.compile("now()")
      assert {:ok, %VRL.Result{value: %DateTime{time_zone: "Etc/UTC"} = dt}} = VRL.run(program)
      assert abs(DateTime.diff(dt, DateTime.utc_now())) < 5
    end

    test "keeps __struct__ on non-DateTime structs by default", %{identity: p} do
      assert {:ok, %VRL.Result{value: %{"__struct__" => "Elixir.URI", "host" => "x"}}} =
               VRL.run(p, URI.parse("http://x"))
    end

    test "strip_structs: true removes __struct__ at any depth", %{identity: p} do
      event = %{"uri" => URI.parse("http://x"), "list" => [~D[2024-01-02]]}

      assert {:ok, %VRL.Result{value: value}} = VRL.run(p, event, strip_structs: true)
      assert %{"uri" => %{"host" => "x"} = uri, "list" => [%{"year" => 2024} = date]} = value
      refute Map.has_key?(uri, "__struct__")
      refute Map.has_key?(date, "__struct__")
    end

    test "strip_structs: true still converts DateTime", %{identity: p} do
      dt = ~U[2024-01-02 03:04:05.123456Z]
      assert {:ok, %VRL.Result{value: ^dt}} = VRL.run(p, dt, strip_structs: true)
    end

    test "returns error for unsupported terms", %{identity: p} do
      assert {:error, message} = VRL.run(p, %{"pid" => self()})
      assert message =~ "unsupported term"
    end

    test "returns error for improper lists", %{identity: p} do
      assert {:error, message} = VRL.run(p, [1, 2 | 3])
      assert message =~ "unsupported term"
    end

    test "returns error for output nested beyond the depth limit" do
      n = VRL.max_depth() + 1
      {:ok, p} = VRL.compile(String.duplicate("[", n) <> "1" <> String.duplicate("]", n))
      assert {:error, "maximum nesting depth of 128 exceeded"} = VRL.run(p)
    end

    test "returns error for integers outside i64", %{identity: p} do
      assert {:error, message} = VRL.run(p, 2 ** 64)
      assert message =~ "unsupported term"
    end
  end
end
