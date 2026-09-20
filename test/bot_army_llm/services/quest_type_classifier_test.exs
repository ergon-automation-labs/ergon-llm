defmodule BotArmyLlm.Services.QuestTypeClassifierTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.QuestTypeClassifier

  describe "classify/4" do
    test "classifies reflection tasks" do
      assert QuestTypeClassifier.classify("Journal about the week") == :reflection
      assert QuestTypeClassifier.classify("Review sprint", nil, ["reflection"]) == :reflection
      assert QuestTypeClassifier.classify("Process feelings") == :reflection
    end

    test "classifies maintenance tasks" do
      assert QuestTypeClassifier.classify("Take medication") == :maintenance
      assert QuestTypeClassifier.classify("Clean the kitchen") == :maintenance
      assert QuestTypeClassifier.classify("Shower") == :maintenance
      assert QuestTypeClassifier.classify("Eat lunch") == :maintenance
    end

    test "classifies exploration tasks" do
      assert QuestTypeClassifier.classify("Read about Elixir") == :exploration

      assert QuestTypeClassifier.classify("Research new framework", nil, ["learning"]) ==
               :exploration

      assert QuestTypeClassifier.classify("Learn TypeScript") == :exploration
    end

    test "classifies collaboration tasks" do
      assert QuestTypeClassifier.classify("Team meeting at 2pm") == :collaboration
      assert QuestTypeClassifier.classify("Sync with Sarah") == :collaboration
      assert QuestTypeClassifier.classify("Ask for feedback", nil, ["social"]) == :collaboration
    end

    test "classifies creation tasks" do
      assert QuestTypeClassifier.classify("Write blog post") == :creation
      assert QuestTypeClassifier.classify("Design new feature", nil, ["creative"]) == :creation
      assert QuestTypeClassifier.classify("Draw the wireframes") == :creation
    end

    test "defaults to combat for ambiguous tasks" do
      assert QuestTypeClassifier.classify("Fix bug #123") == :combat
      assert QuestTypeClassifier.classify("Deploy to production") == :combat
      assert QuestTypeClassifier.classify("Refactor the module") == :combat
    end

    test "case-insensitive matching" do
      assert QuestTypeClassifier.classify("JOURNAL ABOUT THE WEEK") == :reflection
      assert QuestTypeClassifier.classify("Take MEDICATION") == :maintenance
    end
  end

  describe "metadata/1" do
    test "returns metadata for each quest type" do
      metadata = QuestTypeClassifier.metadata(:combat)
      assert metadata[:mechanic] == "boss_fight"
      assert metadata[:emoji] == "⚔️"
      assert is_binary(metadata[:color])
    end

    test "all quest types have metadata" do
      types = [:combat, :reflection, :maintenance, :exploration, :collaboration, :creation]

      Enum.each(types, fn type ->
        metadata = QuestTypeClassifier.metadata(type)
        assert is_map(metadata)
        assert Map.has_key?(metadata, :mechanic)
        assert Map.has_key?(metadata, :emoji)
        assert Map.has_key?(metadata, :color)
      end)
    end
  end
end
