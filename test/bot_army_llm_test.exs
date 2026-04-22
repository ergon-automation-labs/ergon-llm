defmodule BotArmyLlmTest do
  use ExUnit.Case
  @moduletag :core
  doctest BotArmyLlm

  test "version" do
    assert BotArmyLlm.version() == "0.1.0"
  end
end
