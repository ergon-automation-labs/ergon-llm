defmodule BotArmyLlm.ClefTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.Clef

  @models Jason.encode!(%{
            "local" => %{"model" => "clef-flash", "node" => ""},
            "cloud" => %{"model" => "clef:cloud", "node" => ""}
          })

  @questions %{
    "mood" => %{
      "type" => "choice",
      "instructions" => "What does this letter need back?",
      "criteria" => %{"playful" => nil, "tender" => nil, "steady" => nil}
    },
    "needs_care" => %{"type" => "noul", "instructions" => "Is something heavy going on?"}
  }

  @answer %{
    "model" => "clef-flash",
    "answers" => %{
      "mood" => %{"type" => "choice", "choice" => "tender", "probabilities" => %{"tender" => 0.8}},
      "needs_care" => %{"type" => "noul", "noul" => 0.12}
    },
    "usage" => %{"input_tokens" => 120, "output_tokens" => 0}
  }

  setup do
    System.put_env("CLEF_MODELS", @models)
    System.put_env("OLLAMA_URL", "http://ollama.test:11434")
    BotArmyLlm.CircuitBreaker.reset(:clef_local)
    BotArmyLlm.CircuitBreaker.reset(:clef_cloud)

    on_exit(fn ->
      System.delete_env("CLEF_MODELS")
      System.delete_env("OLLAMA_URL")
    end)

    :ok
  end

  defp request(attrs \\ %{}) do
    Map.merge(%{"state" => "dear friend, today was long", "questions" => @questions}, attrs)
  end

  defp ok_post(test_pid) do
    fn url, body, _timeout ->
      send(test_pid, {:posted, url, Jason.decode!(body)})
      {:ok, 200, Jason.encode!(@answer)}
    end
  end

  describe "the request Clef receives" do
    test "local is the default and goes to the node's /v1/systemone with the pillar's model" do
      assert {:ok, reply} = Clef.decide(request(), post: ok_post(self()))

      assert_received {:posted, "http://ollama.test:11434/v1/systemone", body}
      assert body["model"] == "clef-flash"
      assert body["state"] == "dear friend, today was long"
      assert body["questions"] == @questions
      refute Map.has_key?(body, "images")

      assert reply["where"] == "local"
      assert reply["model"] == "clef-flash"
      assert reply["answers"]["mood"]["choice"] == "tender"
      assert reply["answers"]["needs_care"]["noul"] == 0.12
      assert reply["usage"]["input_tokens"] == 120
    end

    test "cloud asks for the pillar's cloud model through the same local node" do
      assert {:ok, reply} = Clef.decide(request(%{"where" => "cloud"}), post: ok_post(self()))

      assert_received {:posted, "http://ollama.test:11434/v1/systemone",
                       %{"model" => "clef:cloud"}}

      assert reply["where"] == "cloud"
    end

    test "a structured state and images are passed through unchanged" do
      state = %{"letter" => "hi", "days_since" => 3}

      assert {:ok, _} =
               Clef.decide(request(%{"state" => state, "images" => ["aGk="]}),
                 post: ok_post(self())
               )

      assert_received {:posted, _url, %{"state" => ^state, "images" => ["aGk="]}}
    end

    test "large asks for the pillar's large model on its node" do
      System.put_env(
        "CLEF_MODELS",
        Jason.encode!(%{"large" => %{"model" => "clef", "node" => "mini"}})
      )

      System.put_env("OLLAMA_MINI_URL", "http://mini.test:11434/")
      on_exit(fn -> System.delete_env("OLLAMA_MINI_URL") end)

      assert {:ok, reply} = Clef.decide(request(%{"where" => "large"}), post: ok_post(self()))
      assert_received {:posted, "http://mini.test:11434/v1/systemone", %{"model" => "clef"}}
      assert reply["where"] == "large"
    end

    test "a mini node with no mini URL configured is refused, not sent to air" do
      System.put_env(
        "CLEF_MODELS",
        Jason.encode!(%{"large" => %{"model" => "clef", "node" => "mini"}})
      )

      System.delete_env("OLLAMA_MINI_URL")
      post = fn _, _, _ -> flunk("nothing should be sent") end

      assert {:error, {:unknown_node, "mini"}} =
               Clef.decide(request(%{"where" => "large"}), post: post)
    end

    test "a named mini node uses the mini URL" do
      System.put_env(
        "CLEF_MODELS",
        Jason.encode!(%{"local" => %{"model" => "clef-flash", "node" => "mini"}})
      )

      System.put_env("OLLAMA_MINI_URL", "http://mini.test:11434")
      on_exit(fn -> System.delete_env("OLLAMA_MINI_URL") end)

      assert {:ok, _} = Clef.decide(request(), post: ok_post(self()))
      assert_received {:posted, "http://mini.test:11434/v1/systemone", _}
    end
  end

  describe "refusals, before anything is sent" do
    test "a where that is not configured is refused by name, never swapped" do
      System.put_env("CLEF_MODELS", Jason.encode!(%{"local" => %{"model" => "clef-flash"}}))
      post = fn _, _, _ -> flunk("nothing should be sent") end

      assert {:error, {:model_not_configured, {:clef, "cloud"}}} =
               Clef.decide(request(%{"where" => "cloud"}), post: post)
    end

    test "no config at all fails closed" do
      System.delete_env("CLEF_MODELS")
      post = fn _, _, _ -> flunk("nothing should be sent") end

      assert {:error, {:model_not_configured, {:clef, "local"}}} =
               Clef.decide(request(), post: post)
    end

    test "an unknown where is refused" do
      assert {:error, {:invalid_request, msg}} =
               Clef.decide(request(%{"where" => "mars"}), post: ok_post(self()))

      assert msg =~ "where"
    end

    test "a missing state, missing questions, or more than 64 questions is refused" do
      post = ok_post(self())

      assert {:error, {:invalid_request, _}} =
               Clef.decide(Map.delete(request(), "state"), post: post)

      assert {:error, {:invalid_request, _}} =
               Clef.decide(Map.delete(request(), "questions"), post: post)

      assert {:error, {:invalid_request, _}} =
               Clef.decide(request(%{"questions" => %{}}), post: post)

      many = Map.new(1..65, fn i -> {"q#{i}", %{"type" => "noul", "instructions" => "x"}} end)

      assert {:error, {:invalid_request, msg}} =
               Clef.decide(request(%{"questions" => many}), post: post)

      assert msg =~ "64"
      refute_received {:posted, _, _}
    end

    test "a question with an unknown type or no instructions is refused, naming it" do
      bad = %{"q" => %{"type" => "essay", "instructions" => "x"}}

      assert {:error, {:invalid_request, msg}} =
               Clef.decide(request(%{"questions" => bad}), post: ok_post(self()))

      assert msg =~ "q"

      bad = %{"r" => %{"type" => "noul"}}

      assert {:error, {:invalid_request, msg}} =
               Clef.decide(request(%{"questions" => bad}), post: ok_post(self()))

      assert msg =~ "r"
    end
  end

  describe "failures" do
    test "an HTTP error is reported with its status and never echoes the state" do
      post = fn _, _, _ -> {:ok, 500, ~s({"error":"model clef-flash not found"})} end

      assert {:error, {:clef_http, 500, detail}} = Clef.decide(request(), post: post)
      assert detail =~ "not found"
      refute inspect(detail) =~ "today was long"
    end

    test "a transport failure trips the breaker for that where only" do
      post = fn _, _, _ -> {:error, :econnrefused} end

      for _ <- 1..5, do: Clef.decide(request(), post: post)

      assert {:error, {:circuit_open, :clef_local, _}} =
               Clef.decide(request(), post: ok_post(self()))

      assert {:ok, _} = Clef.decide(request(%{"where" => "cloud"}), post: ok_post(self()))
    end

    test "a body that is not Clef's answer is an error, not a decision" do
      post = fn _, _, _ -> {:ok, 200, ~s({"message":"hello"})} end
      assert {:error, :clef_bad_answer} = Clef.decide(request(), post: post)
    end
  end
end
