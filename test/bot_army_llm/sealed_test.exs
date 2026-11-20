defmodule BotArmyLlm.SealedTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLlm.Sealed

  @key Base.encode64(:binary.copy(<<7>>, 32))
  @other Base.encode64(:binary.copy(<<9>>, 32))

  setup do
    System.put_env("LLM_SEALED_KEYS", Jason.encode!(%{"k1" => @key, "k2" => @other}))
    on_exit(fn -> System.delete_env("LLM_SEALED_KEYS") end)
    :ok
  end

  test "a sealed map opens to the same map, under the same purpose" do
    {:ok, env} = Sealed.seal(%{"content" => "dear Eir"}, "k1", Sealed.aad(:request, "r1"))
    assert env["v"] == 1 and env["kid"] == "k1" and env["alg"] == "A256GCM"
    refute Jason.encode!(env) =~ "dear Eir"
    assert {:ok, %{"content" => "dear Eir"}} = Sealed.open(env, Sealed.aad(:request, "r1"))
  end

  test "an envelope does not open under another request id or direction" do
    {:ok, env} = Sealed.seal(%{"x" => 1}, "k1", Sealed.aad(:request, "r1"))
    assert {:error, :sealed_bad_ciphertext} = Sealed.open(env, Sealed.aad(:request, "r2"))
    assert {:error, :sealed_bad_ciphertext} = Sealed.open(env, Sealed.aad(:response, "r1"))
  end

  test "a tampered ciphertext does not open" do
    {:ok, env} = Sealed.seal(%{"x" => 1}, "k1", "a")
    <<b, rest::binary>> = Base.decode64!(env["ct"])
    bad = %{env | "ct" => Base.encode64(<<Bitwise.bxor(b, 1), rest::binary>>)}
    assert {:error, :sealed_bad_ciphertext} = Sealed.open(bad, "a")
  end

  test "an unknown kid, no keys, or a malformed envelope is refused by name" do
    {:ok, env} = Sealed.seal(%{"x" => 1}, "k1", "a")
    assert {:error, {:sealed_unknown_key, "k9"}} = Sealed.open(%{env | "kid" => "k9"}, "a")
    assert {:error, {:sealed_unknown_key, "k9"}} = Sealed.seal(%{}, "k9", "a")
    assert {:error, :sealed_malformed} = Sealed.open(%{"v" => 1}, "a")
    assert {:error, :sealed_malformed} = Sealed.open(%{env | "iv" => "!!"}, "a")

    System.delete_env("LLM_SEALED_KEYS")
    assert {:error, :sealed_key_not_configured} = Sealed.open(env, "a")
  end

  test "a key that is not 32 bytes is not a key" do
    System.put_env("LLM_SEALED_KEYS", Jason.encode!(%{"short" => Base.encode64("tooshort")}))
    assert {:error, {:sealed_unknown_key, "short"}} = Sealed.seal(%{}, "short", "a")
  end

  # A fixed vector, so a caller's copy of this module (the companion's) can prove it
  # speaks the same format: same key, iv and aad must give exactly these bytes.
  test "known-answer vector" do
    iv = :binary.copy(<<1>>, 12)
    {:ok, env} = Sealed.seal(%{"content" => "hi"}, "k1", "llm.sealed.v1|request|r1", iv)

    assert env == %{
             "v" => 1,
             "alg" => "A256GCM",
             "kid" => "k1",
             "iv" => "AQEBAQEBAQEBAQEB",
             # Cross-checked 2026-11-19 against Python's cryptography AESGCM (key 0x07*32,
             # iv 0x01*12, plaintext {"content":"hi"}, same aad): byte-identical.
             "ct" => "DcPq2P7LiWCl9uYDGF5STA==",
             "tag" => "om/rTfGK3x0kdB8IylLBLA=="
           }

    assert {:ok, %{"content" => "hi"}} = Sealed.open(env, "llm.sealed.v1|request|r1")
    assert byte_size(Base.decode64!(env["tag"])) == 16
  end

  test "aad/2 names the direction and the request" do
    assert Sealed.aad(:request, "r1") == "llm.sealed.v1|request|r1"
    assert Sealed.aad(:response, "r1") == "llm.sealed.v1|response|r1"
  end
end
