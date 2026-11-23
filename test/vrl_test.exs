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
      assert {:ok, "done", %{"a" => "x", "b" => "X"}} = VRL.run(program, %{"a" => "x"})
    end

    test "program can be reused across runs" do
      {:ok, program} = VRL.compile(".n = int!(.n) + 1")
      assert {:ok, 2, %{"n" => 2}} = VRL.run(program, %{"n" => 1})
      assert {:ok, 11, %{"n" => 11}} = VRL.run(program, %{"n" => 10})
    end

    test "defaults to an empty event" do
      {:ok, program} = VRL.compile(".")
      assert {:ok, %{}, %{}} = VRL.run(program)
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
        assert {:ok, ^v, ^v} = VRL.run(p, v)
      end
    end

    test "round-trips nested maps and lists", %{identity: p} do
      event = %{"a" => [1, %{"b" => [nil, "c"]}], "d" => %{}}
      assert {:ok, ^event, ^event} = VRL.run(p, event)
    end

    test "round-trips non-UTF8 binaries", %{identity: p} do
      assert {:ok, <<255, 0>>, _} = VRL.run(p, <<255, 0>>)
    end

    test "converts atom keys and values to strings", %{identity: p} do
      assert {:ok, %{"a" => "b"}, _} = VRL.run(p, %{a: :b})
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
