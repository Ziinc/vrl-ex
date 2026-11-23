defmodule VRLTest do
  use ExUnit.Case, async: true
  doctest VRL

  describe "compile/1" do
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

    test "requires fallible calls to be handled" do
      assert {:error, message} = VRL.compile(~s(parse_json("{}"\)))
      assert message =~ "unhandled error"
    end
  end

  describe "run/2" do
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

  describe "value conversion" do
    setup do
      {:ok, program} = VRL.compile(".")
      %{identity: program}
    end

    test "round-trips scalars", %{identity: p} do
      for v <- ["str", "", 42, -7, 1.5, true, false, nil] do
        assert {:ok, %VRL.Result{value: ^v, event: ^v}} = VRL.run(p, v)
      end
    end

    test "round-trips nested maps and lists", %{identity: p} do
      event = %{"a" => [1, %{"b" => [nil, "c"]}], "d" => %{}}
      assert {:ok, %VRL.Result{value: ^event, event: ^event}} = VRL.run(p, event)
    end

    test "round-trips non-UTF8 binaries", %{identity: p} do
      assert {:ok, %VRL.Result{value: <<255, 0>>}} = VRL.run(p, <<255, 0>>)
    end

    test "converts atom keys and values to strings", %{identity: p} do
      assert {:ok, %VRL.Result{value: %{"a" => "b"}}} = VRL.run(p, %{a: :b})
    end

    test "converts DateTime to a VRL timestamp" do
      {:ok, program} = VRL.compile("is_timestamp(.t)")

      assert {:ok, %VRL.Result{value: true}} =
               VRL.run(program, %{"t" => ~U[2024-01-02 03:04:05.123456Z]})
    end

    test "round-trips UTC DateTime at microsecond precision", %{identity: p} do
      dt = ~U[2024-01-02 03:04:05.123456Z]

      assert {:ok, %VRL.Result{value: %{"t" => ^dt}, event: %{"t" => ^dt}}} =
               VRL.run(p, %{"t" => dt})
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

    test "returns error for unsupported terms", %{identity: p} do
      assert {:error, message} = VRL.run(p, %{"pid" => self()})
      assert message =~ "unsupported term"
    end

    test "returns error for integers outside i64", %{identity: p} do
      assert {:error, message} = VRL.run(p, 2 ** 64)
      assert message =~ "unsupported term"
    end
  end
end
