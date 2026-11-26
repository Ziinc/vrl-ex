defmodule VRLPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @i64 -(2 ** 63)..(2 ** 63 - 1)

  setup_all do
    {:ok, identity} = VRL.compile(".")
    {:ok, to_json} = VRL.compile("encode_json(.)")
    %{identity: identity, to_json: to_json}
  end

  property "identity program round-trips every supported term", %{identity: p} do
    check all(event <- vrl_term()) do
      assert {:ok, %VRL.Result{value: ^event, event: ^event}} = VRL.run(p, event)
    end
  end

  property "encode_json output decodes back to the input", %{to_json: p} do
    check all(event <- json_term()) do
      assert {:ok, %VRL.Result{value: json}} = VRL.run(p, event)
      assert JSON.decode!(json) == event
    end
  end

  property "run_json round-trips JSON documents", %{identity: p} do
    check all(docs <- list_of(json_term(), max_length: 5)) do
      results = VRL.run_json(p, Enum.map(docs, &JSON.encode!/1))
      assert Enum.map(results, fn {:ok, json, _} -> JSON.decode!(json) end) == docs
    end
  end

  property "run never raises on arbitrary terms", %{identity: p} do
    check all(event <- term()) do
      assert {status, _} = VRL.run(p, event)
      assert status in [:ok, :error]
    end
  end

  property "compile never raises on arbitrary input" do
    check all(source <- one_of([binary(), string(:printable), vrl_like_source()])) do
      assert {status, _} = VRL.compile(source)
      assert status in [:ok, :error]
    end
  end

  property "nesting is accepted up to max_depth and rejected beyond it", %{identity: p} do
    check all(
            depth <- integer(1..(VRL.max_depth() + 20)),
            wrap <- member_of([&[&1], &%{"k" => &1}])
          ) do
      event = Enum.reduce(1..depth, nil, fn _, acc -> wrap.(acc) end)

      if depth <= VRL.max_depth() do
        assert {:ok, %VRL.Result{value: ^event}} = VRL.run(p, event)
      else
        assert {:error, "maximum nesting depth of 128 exceeded"} = VRL.run(p, event)
      end
    end
  end

  defp vrl_term do
    scalar =
      one_of([
        binary(),
        string(:utf8),
        integer(@i64),
        float(),
        boolean(),
        constant(nil),
        map(integer(-62_135_596_800_000_000..253_402_300_799_999_999), fn us ->
          DateTime.from_unix!(us, :microsecond)
        end)
      ])

    tree(scalar, fn child ->
      one_of([list_of(child, max_length: 5), map_of(string(:utf8), child, max_length: 5)])
    end)
  end

  defp json_term do
    scalar = one_of([string(:utf8), integer(@i64), float(), boolean(), constant(nil)])

    tree(scalar, fn child ->
      one_of([list_of(child, max_length: 5), map_of(string(:utf8), child, max_length: 5)])
    end)
  end

  defp vrl_like_source do
    tokens =
      ~w[. .a .b = == + - * / ! ?? , ; ( ) { } "x" 1 2.5 true null if else abort] ++
        ["[", "]", "|", "upcase", "parse_json!", "to_string!", "now()"]

    map(list_of(member_of(tokens), max_length: 30), &Enum.join(&1, " "))
  end
end
