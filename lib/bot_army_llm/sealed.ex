defmodule BotArmyLlm.Sealed do
  @moduledoc """
  Sealed envelopes: private text that crosses NATS as ciphertext, not prose.

  A caller with private words (the companion's letters, which may carry what Abby shared
  and what her systems know) seals the content of its request; this bot opens it in
  memory, runs a local model, and seals the answer back. Anyone subscribed to the bus —
  a wildcard `nats sub '>'` on the prod broker shows every payload — sees only the
  envelope and the routing fields.

      %{"v" => 1, "alg" => "A256GCM", "kid" => "k1", "iv" => b64, "ct" => b64, "tag" => b64}

  AES-256-GCM over the JSON of a map. Every envelope is bound by its additional
  authenticated data to a purpose — `aad(:request | :response, request_id)` — so a sealed
  reply cannot be replayed onto another request, or a request passed off as a reply.

  Keys are the pillar's: `LLM_SEALED_KEYS` is a JSON object of key id to base64 32-byte
  key, rendered from the live-only secrets pillar. No key is named in code; with none
  configured every sealed operation is refused by name (`:sealed_key_not_configured`).
  """

  @version 1
  @alg "A256GCM"
  @iv_bytes 12

  @type envelope :: %{String.t() => term()}

  @doc "The additional authenticated data for one direction of one request."
  @spec aad(:request | :response, String.t()) :: String.t()
  def aad(direction, request_id) when direction in [:request, :response],
    do: "llm.sealed.v#{@version}|#{direction}|#{request_id}"

  @doc "Whether a map carries a sealed envelope."
  @spec sealed?(map()) :: boolean()
  def sealed?(%{"sealed" => %{}}), do: true
  def sealed?(_), do: false

  @doc "Seal a map under key `kid`. `iv` is injectable only for the known-answer test."
  @spec seal(map(), String.t(), String.t(), binary() | nil) ::
          {:ok, envelope()} | {:error, term()}
  def seal(map, kid, aad, iv \\ nil) when is_map(map) and is_binary(aad) do
    with {:ok, key} <- key(kid) do
      iv = iv || :crypto.strong_rand_bytes(@iv_bytes)

      {ct, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, Jason.encode!(map), aad, true)

      {:ok,
       %{
         "v" => @version,
         "alg" => @alg,
         "kid" => kid,
         "iv" => Base.encode64(iv),
         "ct" => Base.encode64(ct),
         "tag" => Base.encode64(tag)
       }}
    end
  end

  @doc "Open an envelope sealed for `aad`."
  @spec open(envelope(), String.t()) :: {:ok, map()} | {:error, term()}
  def open(
        %{"v" => @version, "alg" => @alg, "kid" => kid, "iv" => iv, "ct" => ct, "tag" => tag},
        aad
      )
      when is_binary(kid) and is_binary(iv) and is_binary(ct) and is_binary(tag) and
             is_binary(aad) do
    with {:ok, key} <- key(kid),
         {:ok, iv} <- b64(iv),
         {:ok, ct} <- b64(ct),
         {:ok, tag} <- b64(tag) do
      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ct, aad, tag, false) do
        plain when is_binary(plain) ->
          case Jason.decode(plain) do
            {:ok, %{} = map} -> {:ok, map}
            _ -> {:error, :sealed_malformed}
          end

        :error ->
          {:error, :sealed_bad_ciphertext}
      end
    end
  end

  def open(_envelope, _aad), do: {:error, :sealed_malformed}

  defp b64(text) do
    case Base.decode64(text) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :sealed_malformed}
    end
  end

  defp key(kid) do
    case keys() do
      :none ->
        {:error, :sealed_key_not_configured}

      keys ->
        case Map.get(keys, kid) do
          key when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
          _ -> {:error, {:sealed_unknown_key, kid}}
        end
    end
  end

  defp keys do
    with raw when is_binary(raw) and raw != "" <-
           BotArmyLibraryRuntime.ConfigLoader.get("LLM_SEALED_KEYS"),
         {:ok, %{} = map} when map_size(map) > 0 <- Jason.decode(raw) do
      Map.new(map, fn {kid, b64} ->
        {kid, if(is_binary(b64), do: Base.decode64(b64) |> elem_or_nil(), else: nil)}
      end)
    else
      _ -> :none
    end
  end

  defp elem_or_nil({:ok, bin}), do: bin
  defp elem_or_nil(:error), do: nil
end
