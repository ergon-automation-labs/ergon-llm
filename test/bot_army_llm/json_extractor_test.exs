defmodule BotArmyLlm.JsonExtractorTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLlm.JsonExtractor

  describe "extract/1" do
    test "extracts valid JSON directly" do
      json_text = ~s({"name": "John", "age": 30})
      assert {:ok, %{"name" => "John", "age" => 30}} = JsonExtractor.extract(json_text)
    end

    test "extracts JSON array" do
      json_text = ~s([1, 2, 3, 4])
      assert {:ok, [1, 2, 3, 4]} = JsonExtractor.extract(json_text)
    end

    test "extracts JSON from markdown fence" do
      text = ~s(Here is the result:\n```json\n{"result": "success"}\n```\nEnd)
      assert {:ok, %{"result" => "success"}} = JsonExtractor.extract(text)
    end

    test "extracts JSON from markdown fence without json tag" do
      text = ~s(Result:\n```\n{"data": "value"}\n```\nDone)
      assert {:ok, %{"data" => "value"}} = JsonExtractor.extract(text)
    end

    test "extracts JSON from text with leading content" do
      text = "The response is: {\"key\": \"value\"}"
      assert {:ok, %{"key" => "value"}} = JsonExtractor.extract(text)
    end

    test "returns error when no JSON found" do
      assert {:error, :no_json_found} = JsonExtractor.extract("This is not JSON")
      assert {:error, :no_json_found} = JsonExtractor.extract("")
    end

    test "handles whitespace around JSON" do
      json_text = """

      {
        "name": "test",
        "active": true
      }

      """

      assert {:ok, %{"name" => "test", "active" => true}} = JsonExtractor.extract(json_text)
    end

    test "returns error for invalid input" do
      assert {:error, :no_json_found} = JsonExtractor.extract(nil)
      assert {:error, :no_json_found} = JsonExtractor.extract(123)
    end
  end

  describe "validate_schema/2" do
    test "passes validation when schema is nil" do
      assert :ok = JsonExtractor.validate_schema(%{"any" => "data"}, nil)
    end

    test "validates object type" do
      schema = %{"type" => "object"}
      assert :ok = JsonExtractor.validate_schema(%{"key" => "value"}, schema)
      assert {:error, :schema_mismatch} = JsonExtractor.validate_schema([1, 2, 3], schema)
    end

    test "validates array type" do
      schema = %{"type" => "array"}
      assert :ok = JsonExtractor.validate_schema([1, 2, 3], schema)

      assert {:error, :schema_mismatch} =
               JsonExtractor.validate_schema(%{"key" => "value"}, schema)
    end

    test "validates required properties" do
      schema = %{"required" => ["name", "age"]}
      data = %{"name" => "John", "age" => 30}
      assert :ok = JsonExtractor.validate_schema(data, schema)

      data_missing = %{"name" => "John"}
      assert {:error, :schema_mismatch} = JsonExtractor.validate_schema(data_missing, schema)
    end

    test "validates type and required together" do
      schema = %{"type" => "object", "required" => ["status"]}
      data = %{"status" => "active"}
      assert :ok = JsonExtractor.validate_schema(data, schema)

      data_missing = %{"other" => "field"}
      assert {:error, :schema_mismatch} = JsonExtractor.validate_schema(data_missing, schema)
    end

    test "validates other types" do
      assert :ok = JsonExtractor.validate_schema("string", %{"type" => "string"})
      assert :ok = JsonExtractor.validate_schema(42, %{"type" => "number"})
      assert :ok = JsonExtractor.validate_schema(true, %{"type" => "boolean"})
      assert :ok = JsonExtractor.validate_schema(nil, %{"type" => "null"})
    end
  end

  describe "integration tests" do
    test "extract and validate JSON" do
      text = """
      Here's the analysis:
      ```json
      {
        "confidence": 0.95,
        "classification": "positive"
      }
      ```
      """

      schema = %{"type" => "object", "required" => ["confidence"]}

      {:ok, data} = JsonExtractor.extract(text)
      assert :ok = JsonExtractor.validate_schema(data, schema)
    end

    test "handles malformed fence" do
      text = "```json\n{incomplete"
      assert {:error, :no_json_found} = JsonExtractor.extract(text)
    end
  end
end
