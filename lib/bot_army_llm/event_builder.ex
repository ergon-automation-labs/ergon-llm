defmodule BotArmyLlm.EventBuilder do
  @moduledoc """
  Builds event envelopes for NATS publication.

  Provides a common pattern for constructing event maps with standard metadata.
  """

  @doc """
  Build an event envelope with standard metadata.

  Returns a map with event metadata and the provided payload.

  ## Examples

      iex> event = EventBuilder.build("llm.chain.completed", %{"steps" => 3})
      iex> event["event"]
      "llm.chain.completed"
      iex> event["source"]
      "bot_army_llm"
  """
  @spec build(String.t(), map()) :: map()
  def build(event_type, payload) when is_binary(event_type) and is_map(payload) do
    %{
      "event" => event_type,
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_llm",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "llm.bot",
      "schema_version" => "1.0",
      "payload" => payload
    }
  end
end
