defmodule BotArmyLlm.Services.ReflectionPromptsTest do
  use ExUnit.Case
  @moduletag :services

  alias BotArmyLlm.Services.ReflectionPrompts

  describe "get_prompt/2" do
    test "returns high energy prompts for energy >= 7" do
      prompt = ReflectionPrompts.get_prompt(8, "hopeful")
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "returns medium energy prompts for energy 4-6" do
      prompt = ReflectionPrompts.get_prompt(5, "tender")
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "returns low energy prompts for energy < 4" do
      prompt = ReflectionPrompts.get_prompt(2, "weary_but_moving")
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "defaults to weary_but_moving if no frame provided" do
      prompt = ReflectionPrompts.get_prompt(5)
      assert is_binary(prompt)
    end

    test "returns fallback for unknown frame" do
      prompt = ReflectionPrompts.get_prompt(5, "unknown_frame")
      assert is_binary(prompt)
    end
  end

  describe "get_prompt_rotation/3" do
    test "returns list of prompts for rotation" do
      prompts = ReflectionPrompts.get_prompt_rotation(7, "hopeful", 5)
      assert is_list(prompts)
      assert length(prompts) > 0
      assert Enum.all?(prompts, &is_binary/1)
    end

    test "respects count parameter" do
      prompts = ReflectionPrompts.get_prompt_rotation(5, "defiant", 3)
      assert length(prompts) <= 3
    end

    test "varies prompts by energy level" do
      high_energy = ReflectionPrompts.get_prompt_rotation(8, "hopeful", 3)
      low_energy = ReflectionPrompts.get_prompt_rotation(2, "weary_but_moving", 3)

      # Should have different prompts (statistically)
      assert high_energy != low_energy
    end
  end

  describe "prompts_for_frame/1" do
    test "returns prompts for hopeful frame" do
      prompts = ReflectionPrompts.prompts_for_frame("hopeful")
      assert is_list(prompts)
      assert length(prompts) > 0
    end

    test "returns prompts for all emotional frames" do
      frames = [
        "hopeful",
        "playful",
        "defiant",
        "tender",
        "melancholic_resolve",
        "weary_but_moving"
      ]

      Enum.each(frames, fn frame ->
        prompts = ReflectionPrompts.prompts_for_frame(frame)
        assert length(prompts) > 0, "No prompts for frame: #{frame}"
      end)
    end

    test "returns fallback for unknown frame" do
      prompts = ReflectionPrompts.prompts_for_frame("unknown")
      assert prompts == ["What's on your mind?"]
    end
  end
end
