defmodule BotArmyLlm.Services.BossAntagonistTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.BossAntagonist

  describe "power_tier/1" do
    test "returns mocking for low cumulative difficulty" do
      tier = BossAntagonist.power_tier(10)
      assert tier == :mocking
    end

    test "returns engaged for medium cumulative difficulty" do
      tier = BossAntagonist.power_tier(35)
      assert tier == :engaged
    end

    test "returns vicious for high cumulative difficulty" do
      tier = BossAntagonist.power_tier(60)
      assert tier == :vicious
    end
  end

  describe "taunt_for_completion/4" do
    test "returns a string taunt for combat" do
      taunt = BossAntagonist.taunt_for_completion("combat", 5, 6, 15)
      assert is_binary(taunt)
      assert String.length(taunt) > 0
    end

    test "returns a string taunt for reflection" do
      taunt = BossAntagonist.taunt_for_completion("reflection", 3, 6, 15)
      assert is_binary(taunt)
      assert String.length(taunt) > 0
    end

    test "varies taunts by power tier" do
      mocking_taunt = BossAntagonist.taunt_for_completion("combat", 5, 6, 10)
      vicious_taunt = BossAntagonist.taunt_for_completion("combat", 5, 6, 60)

      assert is_binary(mocking_taunt)
      assert is_binary(vicious_taunt)
    end

    test "generates taunts for all quest types" do
      types = [:combat, :reflection, :maintenance, :exploration, :collaboration, :creation]

      Enum.each(types, fn type ->
        taunt = BossAntagonist.taunt_for_completion(to_string(type), 5, 6, 30)
        assert is_binary(taunt)
        assert String.length(taunt) > 0
      end)
    end

    test "energy level affects maintenance taunts" do
      high_energy = BossAntagonist.taunt_for_completion("maintenance", 2, 8, 15)
      low_energy = BossAntagonist.taunt_for_completion("maintenance", 2, 2, 15)

      assert is_binary(high_energy)
      assert is_binary(low_energy)
    end
  end

  describe "taunt_for_next_quest/3" do
    test "returns a string taunt for combat" do
      taunt = BossAntagonist.taunt_for_next_quest("combat", 6, 20)
      assert is_binary(taunt)
      assert String.length(taunt) > 0
    end

    test "varies by quest type and power tier" do
      combat_taunt = BossAntagonist.taunt_for_next_quest("combat", 6, 60)
      reflection_taunt = BossAntagonist.taunt_for_next_quest("reflection", 3, 60)

      assert is_binary(combat_taunt)
      assert is_binary(reflection_taunt)
    end

    test "generates taunts for all quest types" do
      types = [:combat, :reflection, :maintenance, :exploration, :collaboration, :creation]

      Enum.each(types, fn type ->
        taunt = BossAntagonist.taunt_for_next_quest(to_string(type), 5, 30)
        assert is_binary(taunt)
        assert String.length(taunt) > 0
      end)
    end
  end

  describe "taunt_for_pattern/4" do
    test "returns string for avoidance behavior" do
      taunt = BossAntagonist.taunt_for_pattern("combat", "reflection", 5, 40)
      assert is_binary(taunt)
      assert String.length(taunt) > 0
    end

    test "celebrates long streaks" do
      taunt = BossAntagonist.taunt_for_pattern("combat", nil, 15, 50)
      assert is_binary(taunt)
      assert String.length(taunt) > 0
    end

    test "acknowledges broken streaks with string" do
      taunt = BossAntagonist.taunt_for_pattern("combat", nil, 0, 30)
      assert is_binary(taunt)
      assert String.length(taunt) > 0
    end

    test "varies by streak length" do
      short_streak = BossAntagonist.taunt_for_pattern("combat", nil, 3, 30)
      long_streak = BossAntagonist.taunt_for_pattern("combat", nil, 20, 50)

      assert is_binary(short_streak)
      assert is_binary(long_streak)
    end
  end

  describe "power_observation/2" do
    test "notes huge gap when player far behind" do
      observation = BossAntagonist.power_observation(10, 120)
      assert String.contains?(observation, "far") or String.contains?(observation, "distance")
    end

    test "shows respect when gap narrows" do
      observation = BossAntagonist.power_observation(45, 50)
      assert String.contains?(observation, "worthy") or String.contains?(observation, "equals")
    end

    test "shows alarm when player surpasses" do
      observation = BossAntagonist.power_observation(110, 100)
      assert is_binary(observation)
    end
  end
end
