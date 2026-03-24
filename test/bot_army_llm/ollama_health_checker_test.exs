defmodule BotArmyLlm.OllamaHealthCheckerTest do
  use ExUnit.Case

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
        {:ok, {"http://localhost:11434", "ministral-3:8b"}} = OllamaHealthChecker.best_ollama_node(:heavy)
      end)
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
