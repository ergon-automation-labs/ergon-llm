defmodule BotArmyLlmTest do
  use ExUnit.Case
  doctest BotArmyLlm

  test "version" do
    assert BotArmyLlm.version() == "0.1.0"
  end
end
