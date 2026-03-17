defmodule BotArmyLlm.Telemetry do
  @moduledoc """
  Telemetry event handlers for LLM operations.

  Attaches handlers to telemetry events emitted by LlmClient and other modules,
  routing them to Metrics for collection.
  """

  require Logger

  def setup do
    Logger.info("Setting up telemetry handlers")

    # Request started
    :telemetry.attach(
      "bot_army_llm_request_start",
      [:bot_army_llm, :request, :start],
      &handle_request_start/4,
      nil
    )

    # Request completed
    :telemetry.attach(
      "bot_army_llm_request_stop",
      [:bot_army_llm, :request, :stop],
      &handle_request_stop/4,
      nil
    )

    # Request error
    :telemetry.attach(
      "bot_army_llm_request_error",
      [:bot_army_llm, :request, :error],
      &handle_request_error/4,
      nil
    )

    # Provider fallback
    :telemetry.attach(
      "bot_army_llm_provider_fallback",
      [:bot_army_llm, :provider, :fallback],
      &handle_provider_fallback/4,
      nil
    )

    # RAG index
    :telemetry.attach(
      "bot_army_llm_rag_index",
      [:bot_army_llm, :rag, :index],
      &handle_rag_index/4,
      nil
    )

    # RAG search
    :telemetry.attach(
      "bot_army_llm_rag_search",
      [:bot_army_llm, :rag, :search],
      &handle_rag_search/4,
      nil
    )
  end

  def detach_all do
    Logger.info("Detaching telemetry handlers")

    :telemetry.detach("bot_army_llm_request_start")
    :telemetry.detach("bot_army_llm_request_stop")
    :telemetry.detach("bot_army_llm_request_error")
    :telemetry.detach("bot_army_llm_provider_fallback")
    :telemetry.detach("bot_army_llm_rag_index")
    :telemetry.detach("bot_army_llm_rag_search")
  end

  # Private handlers

  defp handle_request_start(_event, _measurements, metadata, _config) do
    event_type = metadata[:event_type]

    if is_binary(event_type) do
      BotArmyLlm.Metrics.record_request(event_type)
    end
  end

  defp handle_request_stop(_event, measurements, metadata, _config) do
    provider = metadata[:provider]
    latency_ms = measurements[:latency_ms]

    if is_binary(provider) && is_integer(latency_ms) do
      BotArmyLlm.Metrics.record_provider_call(provider, latency_ms)
    end
  end

  defp handle_request_error(_event, _measurements, metadata, _config) do
    event_type = metadata[:event_type]
    error_type = metadata[:error_type]

    if is_binary(event_type) && is_binary(error_type) do
      BotArmyLlm.Metrics.record_error(event_type, error_type)
    end
  end

  defp handle_provider_fallback(_event, _measurements, _metadata, _config) do
    BotArmyLlm.Metrics.record_provider_fallback()
  end

  defp handle_rag_index(_event, _measurements, _metadata, _config) do
    BotArmyLlm.Metrics.record_rag_index()
  end

  defp handle_rag_search(_event, _measurements, _metadata, _config) do
    BotArmyLlm.Metrics.record_rag_search()
  end
end
