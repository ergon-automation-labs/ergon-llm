defmodule BotArmyLlm.JsonExtractor do
  @moduledoc """
  Extracts and validates JSON from text responses.

  Provides fallback strategies for extracting JSON from LLM responses:
  1. Direct JSON parsing
  2. Extract from markdown code fence
  3. Find first JSON object/array

  Also provides schema validation against simple JSON Schema-like specs.
  """

  require Logger

  @doc """
  Extract JSON from text using fallback strategies.

  Returns `{:ok, decoded}` or `{:error, :no_json_found}`.

  ## Strategies
  1. Try Jason.decode directly on the text
  2. Extract from ```json...``` fence
  3. Find and extract first { or [ in the text
  """
  @spec extract(String.t()) :: {:ok, any()} | {:error, :no_json_found}
  def extract(text) when is_binary(text) do
    text = String.trim(text)

    case Jason.decode(text) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _} ->
        case extract_from_fence(text) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> extract_from_text(text)
        end
    end
  end

  def extract(_), do: {:error, :no_json_found}

  @doc """
  Validate JSON data against a schema.

  Returns `:ok` if valid, `{:error, :schema_mismatch}` if invalid.

  Schema is a map with optional keys:
  - `"type"` - "object", "array", or other JSON types
  - `"properties"` - map of property names to schema objects
  - `"required"` - list of required property names

  If schema is nil, validation always passes.

  ## Examples

      iex> JsonExtractor.validate_schema(%{"name" => "John"}, %{"type" => "object"})
      :ok

      iex> JsonExtractor.validate_schema([1, 2, 3], %{"type" => "array"})
      :ok

      iex> JsonExtractor.validate_schema(%{"a" => 1}, nil)
      :ok
  """
  @spec validate_schema(any(), map() | nil) :: :ok | {:error, :schema_mismatch}
  def validate_schema(_data, nil) do
    :ok
  end

  def validate_schema(data, schema) when is_map(schema) do
    valid = do_validate(data, schema)
    if valid, do: :ok, else: {:error, :schema_mismatch}
  end

  def validate_schema(_data, _schema) do
    {:error, :schema_mismatch}
  end

  defp do_validate(data, schema) do
    type_valid = validate_type(data, schema["type"])
    properties_valid = validate_properties(data, schema)
    type_valid && properties_valid
  end

  # Private functions

  defp extract_from_fence(text) do
    # Try to extract from ```json...``` fence
    case Regex.run(~r/```(?:json)?\s*\n?([\s\S]*?)\n?```/m, text) do
      [_match, json_text] ->
        json_text = String.trim(json_text)
        Jason.decode(json_text)

      nil ->
        {:error, :no_fence}
    end
  end

  defp extract_from_text(text) do
    # Get the position of the first bracket
    case Regex.run(~r/[\{\[]/m, text, return: :index) do
      [{pos, _} | _] ->
        substring = String.slice(text, pos..-1//1)
        try_decode_variants(substring)

      nil ->
        {:error, :no_json_found}
    end
  end

  defp try_decode_variants(text) do
    # Try the full text first
    case Jason.decode(text) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> try_truncated_variants(text)
    end
  end

  defp try_truncated_variants(text) do
    # Try removing trailing characters one by one (for incomplete JSON)
    result =
      text
      |> String.graphemes()
      |> Enum.reduce_while(:error, fn _char, :error ->
        case Jason.decode(text) do
          {:ok, decoded} -> {:halt, {:ok, decoded}}
          {:error, _} -> {:cont, :error}
        end
      end)

    case result do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :no_json_found}
    end
  end

  defp validate_type(data, "object"), do: is_map(data)
  defp validate_type(data, "array"), do: is_list(data)
  defp validate_type(data, "string"), do: is_binary(data)
  defp validate_type(data, "number"), do: is_number(data)
  defp validate_type(data, "boolean"), do: is_boolean(data)
  defp validate_type(data, "null"), do: is_nil(data)
  defp validate_type(_data, _type), do: true

  defp validate_properties(data, schema) when is_map(data) and is_map(schema) do
    case schema["required"] do
      required_keys when is_list(required_keys) ->
        Enum.all?(required_keys, &Map.has_key?(data, &1))

      nil ->
        true
    end
  end

  defp validate_properties(_data, _schema) do
    true
  end
end
