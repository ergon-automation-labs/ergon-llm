defmodule BotArmyLlm.SealedDecideTest do
  use ExUnit.Case, async: false
  @moduletag :nats

  alias BotArmyLlm.NATS.Consumer
  alias BotArmyLlm.Sealed

  @secret "I think I want to quit my job"

  setup do
    System.put_env(
      "LLM_SEALED_KEYS",
      Jason.encode!(%{"k1" => Base.encode64(:crypto.strong_rand_bytes(32))})
    )

    on_exit(fn -> System.delete_env("LLM_SEALED_KEYS") end)
    :ok
  end

  defp request(inner, plain \\ %{}) do
    {:ok, env} = Sealed.seal(inner, "k1", Sealed.aad(:request, "d1"))
    Map.merge(%{"request_id" => "d1", "sealed" => env}, plain)
  end

  @inner %{
    "state" => @secret,
    "questions" => %{"heavy" => %{"type" => "noul", "instructions" => "x"}}
  }

  test "the decision sees the opened state; the answers leave sealed" do
    decide = fn req ->
      send(self(), {:asked, req})

      {:ok,
       %{"where" => "local", "model" => "clef-flash", "answers" => %{"heavy" => %{"noul" => 0.8}}}}
    end

    reply = Consumer.decide_response(%{"payload" => request(@inner)}, decide)

    assert_received {:asked, %{"state" => @secret}}
    payload = reply["payload"]
    assert payload["ok"] == true
    assert payload["model"] == "clef-flash"
    refute Map.has_key?(payload, "answers")
    refute Jason.encode!(reply) =~ "quit my job"

    assert {:ok, %{"answers" => %{"heavy" => %{"noul" => 0.8}}}} =
             Sealed.open(payload["sealed"], Sealed.aad(:response, "d1"))
  end

  test "where=cloud is refused for a sealed decision, plain or inside the seal" do
    no = fn _ -> flunk("must not decide") end

    for req <- [
          request(@inner, %{"where" => "cloud"}),
          request(Map.put(@inner, "where", "cloud"))
        ] do
      assert %{"ok" => false, "error" => %{"code" => "sealed_requires_local"}} =
               Consumer.decide_response(req, no)["payload"]
    end
  end

  test "errors are codes only, never the state" do
    for {decide, code} <- [
          {fn _ -> {:error, {:clef_http, 500, @secret}} end, "clef_http"},
          {fn _ -> raise @secret end, "crashed"}
        ] do
      reply = Consumer.decide_response(request(@inner), decide)
      assert reply["payload"]["error"]["code"] == code
      refute Jason.encode!(reply) =~ "quit my job"
    end
  end

  test "a missing request id or key is refused by name" do
    no = fn _ -> flunk("must not decide") end

    assert %{"error" => %{"code" => "sealed_needs_request_id"}} =
             Consumer.decide_response(Map.delete(request(@inner), "request_id"), no)["payload"]

    req = request(@inner)
    System.delete_env("LLM_SEALED_KEYS")

    assert %{"error" => %{"code" => "sealed_key_not_configured"}} =
             Consumer.decide_response(req, no)["payload"]
  end
end
