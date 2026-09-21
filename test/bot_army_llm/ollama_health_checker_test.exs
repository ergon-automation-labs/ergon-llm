defmodule BotArmyLlm.OllamaHealthCheckerTest do
  use ExUnit.Case
  @moduletag :integration

  alias BotArmyLlm.OllamaHealthChecker

  describe "load_acceptable?/0" do
    test "returns true when all metrics are nil (fail-open)" do
      state = %{
        nodes: %{
          air: %{
            url: "http://localhost:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          },
          mini: %{
            url: "",
            latency_ms: nil,
            last_probe_at: nil,
            healthy: false,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      with_state(state, fn ->
        assert OllamaHealthChecker.load_acceptable?() == true
      end)
    end

    test "returns true when memory_pressure=0.5 and cpu_load=0.5 (below defaults)" do
      state = %{
        nodes: %{
          air: %{
            url: "http://localhost:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.5,
            cpu_load: 0.5,
            enabled: true
          },
          mini: %{
            url: "",
            latency_ms: nil,
            last_probe_at: nil,
            healthy: false,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      with_state(state, fn ->
        assert OllamaHealthChecker.load_acceptable?() == true
      end)
    end

    test "returns false when memory_pressure=0.85 (above default 0.80)" do
      state = %{
        nodes: %{
          air: %{
            url: "http://localhost:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.85,
            cpu_load: 0.5,
            enabled: true
          },
          mini: %{
            url: "",
            latency_ms: nil,
            last_probe_at: nil,
            healthy: false,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      with_state(state, fn ->
        assert OllamaHealthChecker.load_acceptable?() == false
      end)
    end

    test "returns false when cpu_load=0.90 (above default 0.80)" do
      state = %{
        nodes: %{
          air: %{
            url: "http://localhost:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.5,
            cpu_load: 0.90,
            enabled: true
          },
          mini: %{
            url: "",
            latency_ms: nil,
            last_probe_at: nil,
            healthy: false,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      with_state(state, fn ->
        assert OllamaHealthChecker.load_acceptable?() == false
      end)
    end

    test "respects custom OLLAMA_HIGH_MEMORY_THRESHOLD env var" do
      state = %{
        nodes: %{
          air: %{
            url: "http://localhost:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.75,
            cpu_load: 0.5,
            enabled: true
          },
          mini: %{
            url: "",
            latency_ms: nil,
            last_probe_at: nil,
            healthy: false,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      # With default 0.80, 0.75 is acceptable
      with_state(state, fn ->
        assert OllamaHealthChecker.load_acceptable?() == true
      end)

      # With custom 0.70, 0.75 is not acceptable
      old_mem = System.get_env("OLLAMA_HIGH_MEMORY_THRESHOLD")

      try do
        System.put_env("OLLAMA_HIGH_MEMORY_THRESHOLD", "0.70")

        with_state(state, fn ->
          assert OllamaHealthChecker.load_acceptable?() == false
        end)
      after
        case old_mem do
          nil -> System.delete_env("OLLAMA_HIGH_MEMORY_THRESHOLD")
          val -> System.put_env("OLLAMA_HIGH_MEMORY_THRESHOLD", val)
        end
      end
    end

    test "respects custom OLLAMA_HIGH_CPU_THRESHOLD env var" do
      state = %{
        nodes: %{
          air: %{
            url: "http://localhost:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.5,
            cpu_load: 0.75,
            enabled: true
          },
          mini: %{
            url: "",
            latency_ms: nil,
            last_probe_at: nil,
            healthy: false,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      # With default 0.80, 0.75 is acceptable
      with_state(state, fn ->
        assert OllamaHealthChecker.load_acceptable?() == true
      end)

      # With custom 0.70, 0.75 is not acceptable
      old_cpu = System.get_env("OLLAMA_HIGH_CPU_THRESHOLD")

      try do
        System.put_env("OLLAMA_HIGH_CPU_THRESHOLD", "0.70")

        with_state(state, fn ->
          assert OllamaHealthChecker.load_acceptable?() == false
        end)
      after
        case old_cpu do
          nil -> System.delete_env("OLLAMA_HIGH_CPU_THRESHOLD")
          val -> System.put_env("OLLAMA_HIGH_CPU_THRESHOLD", val)
        end
      end
    end

    test "ignores disabled nodes" do
      state = %{
        nodes: %{
          air: %{
            url: "http://localhost:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.95,
            cpu_load: 0.95,
            enabled: false
          },
          mini: %{
            url: "",
            latency_ms: nil,
            last_probe_at: nil,
            healthy: false,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      with_state(state, fn ->
        # Even though air has high load, it's disabled, so all enabled nodes are acceptable
        assert OllamaHealthChecker.load_acceptable?() == true
      end)
    end
  end

  describe "best_ollama_node/1" do
    test "prefers lower-latency node when both healthy" do
      state = %{
        nodes: %{
          air: %{
            url: "http://air:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.5,
            cpu_load: 0.5,
            enabled: true
          },
          mini: %{
            url: "http://mini:11434",
            latency_ms: 50,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.5,
            cpu_load: 0.5,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      with_state(state, fn ->
        {:ok, {url, _model}} = OllamaHealthChecker.best_ollama_node(:light)
        assert url == "http://mini:11434"
      end)
    end

    test "penalizes node with high memory_pressure (5000ms added to sort)" do
      state = %{
        nodes: %{
          air: %{
            url: "http://air:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.75,
            cpu_load: 0.5,
            enabled: true
          },
          mini: %{
            url: "http://mini:11434",
            latency_ms: 2000,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.5,
            cpu_load: 0.5,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      with_state(state, fn ->
        {:ok, {url, _model}} = OllamaHealthChecker.best_ollama_node(:light)
        # air: 100 + 5000 penalty (memory_pressure=0.75 > 0.7) = 5100
        # mini: 2000 + 0 penalty (memory_pressure=0.5 <= 0.7) = 2000
        # mini should win due to penalty on air
        assert url == "http://mini:11434"
      end)
    end

    test "high memory pressure node loses to low latency node when penalty applies" do
      state = %{
        nodes: %{
          air: %{
            url: "http://air:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.8,
            cpu_load: 0.5,
            enabled: true
          },
          mini: %{
            url: "http://mini:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.5,
            cpu_load: 0.5,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      with_state(state, fn ->
        {:ok, {url, _model}} = OllamaHealthChecker.best_ollama_node(:light)
        # air: 100 + 5000 penalty = 5100 (memory_pressure > 0.7)
        # mini: 100 + 0 penalty = 100
        # mini should win due to penalty on air
        assert url == "http://mini:11434"
      end)
    end

    test "returns error when no healthy nodes available" do
      state = %{
        nodes: %{
          air: %{
            url: "http://localhost:11434",
            latency_ms: nil,
            last_probe_at: DateTime.utc_now(),
            healthy: false,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          },
          mini: %{
            url: "",
            latency_ms: nil,
            last_probe_at: nil,
            healthy: false,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      with_state(state, fn ->
        {:error, :no_healthy_nodes} = OllamaHealthChecker.best_ollama_node(:light)
      end)
    end

    test "supports heavy complexity by routing to healthy Ollama nodes" do
      state = %{
        nodes: %{
          air: %{
            url: "http://localhost:11434",
            latency_ms: 100,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.5,
            cpu_load: 0.5,
            enabled: true
          },
          mini: %{
            url: "",
            latency_ms: nil,
            last_probe_at: nil,
            healthy: false,
            memory_pressure: nil,
            cpu_load: nil,
            enabled: true
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }

      with_state(state, fn ->
        {:ok, {"http://localhost:11434", "ministral-3:8b"}} =
          OllamaHealthChecker.best_ollama_node(:heavy)
      end)
    end
  end

  describe "best_ollama_node/2 (explicit node pinning)" do
    # Mini holds models air does not (baytout3/qwen3.5-uncensored:27B) and must
    # never win implicit latency routing.
    defp pinned_state do
      %{
        nodes: %{
          air: %{
            url: "http://air:11434",
            latency_ms: 10,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.1,
            cpu_load: 0.1,
            enabled: true,
            explicit_only: false,
            default_model: nil,
            probe_model: nil
          },
          mini: %{
            url: "http://mini:11434",
            latency_ms: 9_000,
            last_probe_at: DateTime.utc_now(),
            healthy: true,
            memory_pressure: 0.2,
            cpu_load: 0.2,
            enabled: true,
            explicit_only: true,
            default_model: "baytout3/qwen3.5-uncensored:27B",
            probe_model: "lfm2.5:latest"
          }
        },
        probe_model: "gemma3:1b",
        degraded_latency_ms: 8000
      }
    end

    test "a named node wins over a faster node and keeps its own model" do
      with_state(pinned_state(), fn ->
        assert {:ok, {"http://mini:11434", "baytout3/qwen3.5-uncensored:27B"}} =
                 OllamaHealthChecker.best_ollama_node(:light, "mini")

        # atom form is equivalent
        assert {:ok, {"http://mini:11434", "baytout3/qwen3.5-uncensored:27B"}} =
                 OllamaHealthChecker.best_ollama_node(:light, :mini)
      end)
    end

    test "implicit routing skips explicit-only nodes" do
      with_state(pinned_state(), fn ->
        assert {:ok, {"http://air:11434", _model}} = OllamaHealthChecker.best_ollama_node(:light)

        assert {:ok, {"http://air:11434", _model}} =
                 OllamaHealthChecker.best_ollama_node(:light, nil)

        assert {:ok, {"http://air:11434", _model}} =
                 OllamaHealthChecker.best_ollama_node(:light, "")

        assert {:ok, {"http://air:11434", _model}} =
                 OllamaHealthChecker.best_ollama_node(:light, "auto")
      end)
    end

    test "an explicit-only node that is the only healthy node yields no implicit route" do
      state = pinned_state()
      state = put_in(state.nodes.air.healthy, false)

      with_state(state, fn ->
        assert {:error, :no_healthy_nodes} = OllamaHealthChecker.best_ollama_node(:light)
      end)
    end

    test "a named node without a url reports node_not_configured" do
      state = pinned_state()
      state = put_in(state.nodes.mini.url, "")

      with_state(state, fn ->
        assert {:error, {:node_not_configured, "mini"}} =
                 OllamaHealthChecker.best_ollama_node(:light, "mini")
      end)
    end

    test "a named unhealthy node reports node_unhealthy" do
      state = pinned_state()
      state = put_in(state.nodes.mini.healthy, false)

      with_state(state, fn ->
        assert {:error, {:node_unhealthy, "mini"}} =
                 OllamaHealthChecker.best_ollama_node(:light, "mini")
      end)
    end

    test "an unknown node name reports unknown_node" do
      with_state(pinned_state(), fn ->
        assert {:error, {:unknown_node, "nope"}} =
                 OllamaHealthChecker.best_ollama_node(:light, "nope")
      end)
    end

    test "a named node without a default model falls back to complexity tiers" do
      state = pinned_state()
      state = put_in(state.nodes.mini.default_model, nil)

      with_state(state, fn ->
        assert {:ok, {"http://mini:11434", model}} =
                 OllamaHealthChecker.best_ollama_node(:light, "mini")

        assert is_binary(model)
      end)
    end

    # ── the :uncensored type ────────────────────────────────────────────────
    # The uncensored family is named by the pillar per node, and it has no
    # fallback: a substituted smaller model answers intimate content with a
    # refusal, which is indistinguishable from a content problem at the caller.
    test "resolves :uncensored to OLLAMA_MODEL_UNCENSORED" do
      with_env("OLLAMA_MODEL_UNCENSORED", "baytout3/qwen3.5-uncensored:9B", fn ->
        with_state(pinned_state(), fn ->
          assert {:ok, {"http://air:11434", "baytout3/qwen3.5-uncensored:9B"}} =
                   OllamaHealthChecker.best_ollama_node(:uncensored)
        end)
      end)
    end

    test "an explicit node's own uncensored model still wins" do
      with_env("OLLAMA_MODEL_UNCENSORED", "baytout3/qwen3.5-uncensored:9B", fn ->
        with_state(pinned_state(), fn ->
          assert {:ok, {"http://mini:11434", "baytout3/qwen3.5-uncensored:27B"}} =
                   OllamaHealthChecker.best_ollama_node(:uncensored, "mini")
        end)
      end)
    end

    test "fails closed when no uncensored model is configured" do
      with_env("OLLAMA_MODEL_UNCENSORED", nil, fn ->
        state = pinned_state()
        state = put_in(state.nodes.air.default_model, nil)

        with_state(state, fn ->
          assert {:error, {:model_not_configured, :uncensored}} =
                   OllamaHealthChecker.best_ollama_node(:uncensored)
        end)
      end)
    end

    test "a blank model is reported, not passed on to Ollama" do
      # The regression this guards: posting model:"" to Ollama yields a 400 whose
      # text says nothing about the missing setting.
      with_env("OLLAMA_MODEL_UNCENSORED", " ", fn ->
        with_state(pinned_state(), fn ->
          assert {:error, {:model_not_configured, :uncensored}} =
                   OllamaHealthChecker.best_ollama_node(:uncensored)
        end)
      end)
    end

    test "node_status exposes explicit_only" do
      with_state(pinned_state(), fn ->
        status = OllamaHealthChecker.node_status()

        assert %{explicit_only: false} = Enum.find(status, &(&1.name == :air))
        assert %{explicit_only: true} = Enum.find(status, &(&1.name == :mini))
      end)
    end
  end

  # Set (or clear) a single env var for the duration of one test.
  defp with_env(key, value, func) do
    previous = System.get_env(key)

    case value do
      nil -> System.delete_env(key)
      _ -> System.put_env(key, value)
    end

    try do
      func.()
    after
      case previous do
        nil -> System.delete_env(key)
        _ -> System.put_env(key, previous)
      end
    end
  end

  # Helper to temporarily replace GenServer state
  defp with_state(new_state, func) do
    # Start the health checker if not running
    case Process.whereis(OllamaHealthChecker) do
      nil -> OllamaHealthChecker.start_link()
      _ -> :ok
    end

    # Replace its state
    :sys.replace_state(OllamaHealthChecker, fn _state -> new_state end)

    try do
      func.()
    after
      # Restore by triggering a probe (which will rebuild state from config)
      # For simplicity, we'll just leave it — each test gets fresh state via with_state
      :ok
    end
  end
end
