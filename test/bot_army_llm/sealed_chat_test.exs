defmodule BotArmyLlm.SealedChatTest do
  use ExUnit.Case, async: false
  @moduletag :nats

  alias BotArmyLlm.{JobStore, Sealed}
  alias BotArmyLlm.NATS.Consumer

  @secret "my sister and I haven't spoken since June"

  setup do
    key = Base.encode64(:crypto.strong_rand_bytes(32))
    System.put_env("LLM_SEALED_KEYS", Jason.encode!(%{"k1" => key}))
    on_exit(fn -> System.delete_env("LLM_SEALED_KEYS") end)
    :ok
  end

  defp sealed(inner, plain \\ %{}, rid \\ "r1") do
    {:ok, env} = Sealed.seal(inner, "k1", Sealed.aad(:request, rid))
    Map.merge(%{"request_id" => rid, "sealed" => env}, plain)
  end

  defp letter, do: %{"prompt_context" => %{"prompt" => @secret}}

  # The model: echoes the prompt it was given, so a leak would carry the secret.
  defp echo(test) do
    fn payload, _subject ->
      send(test, {:ran_with, payload})

      %{
        "request_id" => payload["request_id"],
        "content" => "reply to: " <> get_in(payload, ["prompt_context", "prompt"]),
        "model_used" => "m"
      }
    end
  end

  describe "prepare_chat/2 refusals (no model runs)" do
    test "a sealed request must run locally" do
      no_model = fn _, _ -> flunk("must not run") end

      for plain <- [
            %{},
            %{"source" => "local_ollama", "provider" => "openrouter"},
            %{"model_type" => "fast"}
          ] do
        assert {:refuse, %{"ok" => false, "error" => "sealed_requires_local"}} =
                 Consumer.prepare_chat(sealed(letter(), plain), no_model)
      end
    end

    test "sealed fields cannot route it to the cloud after opening" do
      inner = Map.merge(letter(), %{"provider" => "anthropic"})

      assert {:refuse, %{"error" => "sealed_requires_local"}} =
               Consumer.prepare_chat(sealed(inner, %{"source" => "local_ollama"}), fn _, _ ->
                 flunk("ran")
               end)
    end

    test "no request_id, a wrong request_id, or no key is refused by name" do
      req = sealed(letter(), %{"source" => "local_ollama"})

      assert {:refuse, %{"error" => "sealed_needs_request_id"}} =
               Consumer.prepare_chat(Map.delete(req, "request_id"), fn _, _ -> flunk("ran") end)

      assert {:refuse, %{"error" => "sealed_bad_ciphertext"}} =
               Consumer.prepare_chat(%{req | "request_id" => "r2"}, fn _, _ -> flunk("ran") end)

      System.delete_env("LLM_SEALED_KEYS")

      assert {:refuse, %{"error" => "sealed_key_not_configured"}} =
               Consumer.prepare_chat(req, fn _, _ -> flunk("ran") end)
    end

    test "a plain request is untouched" do
      run = fn _, _ -> :ran end
      assert {:ok, %{"x" => 1}, ^run} = Consumer.prepare_chat(%{"x" => 1}, run)
    end
  end

  describe "the sealed round trip" do
    test "the model sees the opened prompt; the reply carries it only sealed" do
      {:ok, opened, runner} =
        Consumer.prepare_chat(sealed(letter(), %{"source" => "local_ollama"}), echo(self()))

      refute Map.has_key?(opened, "sealed")
      reply = runner.(opened, "llm.request.chat")

      assert_received {:ran_with,
                       %{"prompt_context" => %{"prompt" => @secret}, "source" => "local_ollama"}}

      refute Jason.encode!(reply) =~ "sister"
      refute Map.has_key?(reply, "content")
      assert reply["model_used"] == "m"
      assert reply["request_id"] == "r1"

      assert {:ok, %{"content" => "reply to: " <> @secret}} =
               Sealed.open(reply["sealed"], Sealed.aad(:response, "r1"))

      # bound to its direction: a reply cannot be passed off as a request
      assert {:error, :sealed_bad_ciphertext} =
               Sealed.open(reply["sealed"], Sealed.aad(:request, "r1"))
    end

    test "uncensored counts as local" do
      assert {:ok, _, _} =
               Consumer.prepare_chat(
                 sealed(letter(), %{"model_type" => "uncensored"}),
                 echo(self())
               )
    end

    test "an async sealed job stores only the sealed reply" do
      {:ok, opened, runner} =
        Consumer.prepare_chat(sealed(letter(), %{"source" => "local_ollama"}), echo(self()))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          %{"job_id" => job_id} = Consumer.submit_chat_job(opened, "llm.request.chat", runner)
          send(self(), {:job, job_id})
          Process.sleep(100)
        end)

      assert_received {:job, job_id}
      assert {:ok, %{status: :completed, result: result}} = JobStore.get(job_id)
      refute inspect(result) =~ "sister"
      refute log =~ "sister"
      assert {:ok, %{"content" => _}} = Sealed.open(result["sealed"], Sealed.aad(:response, "r1"))
    end

    test "a crash inside the model never puts the prompt in a log or the job store" do
      boom = fn payload, _ ->
        raise "provider choked on: " <> get_in(payload, ["prompt_context", "prompt"])
      end

      {:ok, opened, runner} =
        Consumer.prepare_chat(sealed(letter(), %{"source" => "local_ollama"}), boom)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          %{"job_id" => job_id} = Consumer.submit_chat_job(opened, "llm.request.chat", runner)
          send(self(), {:job, job_id})
          Process.sleep(100)
        end)

      assert_received {:job, job_id}
      {:ok, job} = JobStore.get(job_id)
      refute log =~ "sister"
      refute inspect(job) =~ "sister"
      assert job.result["error"] == "sealed_crashed"
    end

    test "a model error's text is replaced by a code" do
      fail = fn _, _ -> %{"request_id" => "r1", "error" => "{:ollama, \"#{@secret}\"}"} end

      {:ok, opened, runner} =
        Consumer.prepare_chat(sealed(letter(), %{"source" => "local_ollama"}), fail)

      reply = runner.(opened, "llm.request.chat")
      assert reply["error"] == "model_error"
      refute Jason.encode!(reply) =~ "sister"
    end
  end
end
