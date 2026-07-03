defmodule BotArmyLlm.HttpFallback do
  @moduledoc false
  # POST with an automatic direct-upstream fallback.
  #
  # When an upstream provider is fronted by the headroom context-optimization
  # proxy (e.g. ANTHROPIC_BASE_URL -> http://127.0.0.1:8787), a missing or
  # broken headroom must not break the fleet: we retry the same request against
  # the real provider URL and log a [headroom-down] warning. When the primary
  # and fallback URLs are identical (headroom not wired, default env), this is
  # a plain HTTPoison.post with no extra attempt.

  require Logger

  @spec post_with_fallback(String.t(), String.t() | nil, term(), list(), keyword()) ::
          {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  def post_with_fallback(url, fallback_url, body, headers, opts \\ [])

  def post_with_fallback(url, nil, body, headers, opts) do
    HTTPoison.post(url, body, headers, opts)
  end

  def post_with_fallback(url, url, body, headers, opts) do
    HTTPoison.post(url, body, headers, opts)
  end

  def post_with_fallback(url, fallback_url, body, headers, opts) do
    case HTTPoison.post(url, body, headers, opts) do
      {:ok, %HTTPoison.Response{status_code: sc}} = ok when sc < 500 ->
        ok

      {:ok, %HTTPoison.Response{status_code: sc}} ->
        Logger.warning(
          "[headroom-down] #{url} returned HTTP #{sc}; falling back to #{fallback_url}"
        )

        HTTPoison.post(fallback_url, body, headers, opts)

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning(
          "[headroom-down] #{url} unreachable (#{inspect(reason)}); falling back to #{fallback_url}"
        )

        HTTPoison.post(fallback_url, body, headers, opts)

      other ->
        other
    end
  end
end
