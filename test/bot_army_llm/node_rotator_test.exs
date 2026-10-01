defmodule BotArmyLlm.NodeRotatorTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLlm.NodeRotator

  # The env var is read by `weights/0` on every call, but the running GenServer
  # reads its schedule once at start-up — so these tests assert the pure parsing
  # against the env var and the rotation against the default schedule the test
  # environment starts with (see the assertion in "rotates through the weighted
  # schedule" for why that is the default and not a hardcoded guess).
  setup do
    previous = System.get_env("OLLAMA_ROUND_ROBIN_WEIGHTS")

    on_exit(fn ->
      if previous do
        System.put_env("OLLAMA_ROUND_ROBIN_WEIGHTS", previous)
      else
        System.delete_env("OLLAMA_ROUND_ROBIN_WEIGHTS")
      end
    end)

    NodeRotator.reset()
    :ok
  end

  describe "weights/0" do
    test "defaults to two shares of air to one of mini" do
      System.delete_env("OLLAMA_ROUND_ROBIN_WEIGHTS")

      assert NodeRotator.weights() == [{"air", 2}, {"mini", 1}]
      assert NodeRotator.schedule() == ["air", "air", "mini"]
    end

    test "reads the shares from OLLAMA_ROUND_ROBIN_WEIGHTS" do
      System.put_env("OLLAMA_ROUND_ROBIN_WEIGHTS", "mini:3,air:1")

      assert NodeRotator.weights() == [{"mini", 3}, {"air", 1}]
      assert NodeRotator.schedule() == ["mini", "mini", "mini", "air"]
    end

    test "a bare name means one share and a non-positive weight drops the name" do
      System.put_env("OLLAMA_ROUND_ROBIN_WEIGHTS", "air,mini:0")

      assert NodeRotator.weights() == [{"air", 1}]
    end

    test "a bare token is a weight-1 node name, and a name that matches no node is inert" do
      # The schedule is a preference list, not an authority: next/1 only ever returns a
      # name the caller offered, so a typo'd name is never chosen and cannot strand a
      # call. The cost of a typo is that node being unused, not a failed request.
      System.put_env("OLLAMA_ROUND_ROBIN_WEIGHTS", "!!!,mini:not-a-number")

      assert NodeRotator.weights() == [{"!!!", 1}]
    end
  end

  describe "next/1" do
    test "rotates through the weighted schedule" do
      assert NodeRotator.schedule() == ["air", "air", "mini"],
             "test environment should start on the default schedule"

      NodeRotator.reset()

      assert Enum.map(1..4, fn _ -> NodeRotator.next([:air, :mini]) end) ==
               ["air", "air", "mini", "air"]
    end

    test "skips a scheduled node the caller did not offer" do
      NodeRotator.reset()

      assert NodeRotator.next([:mini]) == "mini"
      assert NodeRotator.next([:mini]) == "mini"
      assert NodeRotator.next(["mini"]) == "mini"
    end

    test "an empty rotation is nil, never a default node" do
      assert NodeRotator.next([]) == nil
    end
  end
end
