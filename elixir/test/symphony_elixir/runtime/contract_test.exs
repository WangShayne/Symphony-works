defmodule SymphonyElixir.Runtime.ContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Runtime
  alias SymphonyElixir.Runtime.Codex
  alias SymphonyElixir.Runtime.Simulated

  defmodule FakeAppServer do
    def start_session("/tmp/codex", opts) when is_list(opts) do
      if Keyword.has_key?(opts, :health_probe), do: assert_health_probe_mode!(opts)

      if Keyword.get(opts, :worker) in ["local", nil] do
        {:ok, %{thread_id: "thread-codex"}}
      else
        {:error, :unexpected_worker}
      end
    end

    def start_session("/tmp/probe-invalid", opts), do: health_start(opts, "thread-probe-invalid")
    def start_session("/tmp/probe-turn-fail", opts), do: health_start(opts, "thread-probe-turn-fail")
    def start_session("/tmp/probe-stop-fail", opts), do: health_start(opts, "thread-stop-error")
    def start_session("/tmp/probe-string-result", opts), do: health_start(opts, "thread-probe-string-result")

    def start_session("/tmp/provider-bound", opts) do
      assert_health_probe_mode!(opts)
      binding = Keyword.fetch!(opts, :provider_binding)
      assert binding.endpoint == "https://models.example.test/v1"
      assert binding.model_id == "configured-health-model"
      assert binding.credential == "BROKERED_PROVIDER_SECRET"
      {:ok, %{thread_id: "thread-provider-bound", test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    def start_session("/tmp/bad-return", []), do: :bad

    def start_session("/tmp/fail", opts) do
      if Keyword.has_key?(opts, :health_probe), do: assert_health_probe_mode!(opts)
      {:error, :offline}
    end

    def start_session("/tmp/malformed", []), do: {:ok, %{}}
    def start_session("/tmp/crash", []), do: raise("boom")
    def start_session("/tmp/exit", []), do: exit({:shutdown, "SECRET=start"})
    def start_session("/tmp/throw", []), do: throw({:unsafe, "SECRET=start"})

    def run_turn(%{thread_id: "thread-codex"}, "prompt", %{}, worker: "local") do
      {:ok, %{result: %{"ok" => true}, session_id: "thread-codex-turn-1", thread_id: "thread-codex", turn_id: "turn-1"}}
    end

    def run_turn(%{thread_id: "thread-codex"}, "fail", %{}, []), do: {:error, :turn_failed}
    def run_turn(%{thread_id: "thread-codex"}, "malformed", %{}, []), do: {:ok, :bad}
    def run_turn(%{thread_id: "thread-codex"}, "crash", %{}, []), do: raise("boom")
    def run_turn(%{thread_id: "thread-codex"}, "exit", %{}, []), do: exit({:shutdown, "SECRET=turn"})
    def run_turn(%{thread_id: "thread-codex"}, "throw", %{}, []), do: throw({:unsafe, "SECRET=turn"})

    def run_turn(%{thread_id: "thread-codex"}, prompt, %{identifier: "runtime-capability-probe"}, opts)
        when is_binary(prompt) and is_list(opts) do
      if Keyword.has_key?(opts, :health_probe), do: assert_health_probe_mode!(opts)

      {:ok, %{result: %{"task_type" => "general"}, session_id: "thread-codex-probe", thread_id: "thread-codex", turn_id: "probe"}}
    end

    def run_turn(%{thread_id: "thread-provider-bound"}, _prompt, %{identifier: "runtime-capability-probe"} = issue, opts) do
      assert_health_probe_mode!(opts)
      binding = Keyword.fetch!(opts, :provider_binding)
      assert issue.title == "Read-only structured plan probe"
      assert issue.model_reference_id == "provider-bound-model"
      assert binding.model_id == "configured-health-model"
      assert binding.credential == "BROKERED_PROVIDER_SECRET"

      {:ok, %{result: %{"task_type" => "general"}}}
    end

    def run_turn(%{thread_id: "thread-probe-invalid"}, _prompt, %{identifier: "runtime-capability-probe"}, opts) do
      assert_health_probe_mode!(opts)
      {:ok, %{result: %{"invalid" => true}}}
    end

    def run_turn(%{thread_id: "thread-probe-turn-fail"}, _prompt, %{identifier: "runtime-capability-probe"}, opts) do
      assert_health_probe_mode!(opts)
      {:error, {:offline, "SECRET=health"}}
    end

    def run_turn(%{thread_id: "thread-stop-error"}, _prompt, %{identifier: "runtime-capability-probe"}, opts) do
      assert_health_probe_mode!(opts)
      {:ok, %{result: %{"task_type" => "general"}}}
    end

    def run_turn(%{thread_id: "thread-probe-string-result"}, _prompt, %{identifier: "runtime-capability-probe"}, opts) do
      assert_health_probe_mode!(opts)
      {:ok, %{"result" => %{"task_type" => "general"}}}
    end

    def stop_session(%{thread_id: "thread-codex"}), do: :ok

    def stop_session(%{thread_id: "thread-provider-bound", test_pid: test_pid}) do
      send(test_pid, :provider_bound_stopped)
      :ok
    end

    def stop_session(%{thread_id: "thread-probe-string-result"}), do: :ok
    def stop_session(%{thread_id: "thread-stop-error"}), do: {:error, {:offline, "SECRET=stop"}}
    def stop_session(%{thread_id: "thread-stop-raise"}), do: raise("SECRET=stop")
    def stop_session(%{thread_id: "thread-stop-exit"}), do: exit({:shutdown, "SECRET=stop"})
    def stop_session(%{thread_id: "thread-stop-bad-return"}), do: :bad

    defp assert_health_probe_mode!(opts), do: true = Keyword.fetch!(opts, :health_probe)

    defp health_start(opts, thread_id) do
      assert_health_probe_mode!(opts)
      {:ok, %{thread_id: thread_id}}
    end
  end

  defmodule UnsafeAdapter do
    @behaviour Runtime

    def start_session(%{mode: :raise}), do: raise("SECRET=start")
    def start_session(%{mode: :exit}), do: exit({:shutdown, "SECRET=start"})
    def start_session(%{mode: :throw}), do: throw({:unsafe, "SECRET=start"})
    def start_session(%{mode: :error}), do: {:error, {:runtime_error, :existing_start_error}}
    def start_session(_opts), do: {:ok, %Runtime.Session{adapter: __MODULE__, runtime: :unsafe, session_id: "unsafe", metadata: %{}}}

    def run_turn(_session, %{mode: :raise}), do: raise("SECRET=turn")
    def run_turn(_session, %{mode: :exit}), do: exit({:shutdown, "SECRET=turn"})
    def run_turn(_session, %{mode: :throw}), do: throw({:unsafe, "SECRET=turn"})
    def run_turn(_session, %{mode: :error}), do: {:error, {:runtime_error, :existing_turn_error}}
    def run_turn(session, _input), do: {:ok, %Runtime.TurnResult{runtime: :unsafe, session_id: session.session_id, output: %{}, events: []}}

    def stop_session(%Runtime.Session{adapter_state: :raise}), do: raise("SECRET=stop")
    def stop_session(%Runtime.Session{adapter_state: :exit}), do: exit({:shutdown, "SECRET=stop"})
    def stop_session(%Runtime.Session{adapter_state: :throw}), do: throw({:unsafe, "SECRET=stop"})
    def stop_session(%Runtime.Session{adapter_state: :error}), do: {:error, {:runtime_error, :existing_stop_error}}
    def stop_session(_session), do: :ok

    def capabilities(_opts), do: raise("SECRET=capabilities")
    def health_check(_opts, _health_opts), do: exit({:shutdown, "SECRET=health"})
  end

  test "simulated adapter implements deterministic session lifecycle and normalized events" do
    assert {:ok, session} =
             Runtime.start_session(Simulated, %{
               runtime: "simulated",
               workspace: "/tmp/symphony-runtime-contract",
               model_reference: model_reference(),
               seed: 7
             })

    assert session.runtime == :simulated
    assert is_binary(session.session_id)

    assert {:ok, result} =
             Runtime.run_turn(session, %{
               prompt: "Return a schema-valid routing decision.",
               schema: %{
                 "type" => "object",
                 "required" => ["task_type"],
                 "properties" => %{"task_type" => %{"type" => "string"}}
               }
             })

    assert result.session_id == session.session_id
    assert result.output == %{"task_type" => "general"}
    assert Enum.map(result.events, & &1.type) == [:session_started, :turn_completed]
    assert Enum.all?(result.events, &(&1.runtime == :simulated))

    assert :ok = Runtime.stop_session(session)
  end

  test "simulated adapter can return deterministic non-schema output" do
    {:ok, session} = Runtime.start_session(Simulated, %{"workspace" => "/tmp/sim", "seed" => 1})

    assert {:ok, result} = Runtime.run_turn(session, %{"prompt" => "status"})
    assert result.output == %{"message" => "simulated"}
    assert Runtime.event(:simulated, :custom, session.session_id).payload == %{}
  end

  test "codex adapter wraps AppServer sessions and normalizes turn results" do
    assert {:ok, session} =
             Runtime.start_session(Codex, %{
               workspace: "/tmp/codex",
               app_server: FakeAppServer,
               app_server_opts: [worker: "local"],
               model_reference: model_reference()
             })

    assert session.runtime == :codex
    assert session.session_id == "thread-codex"

    assert {:ok, result} =
             Runtime.run_turn(session, %{
               prompt: "prompt",
               app_server_opts: [worker: "local"]
             })

    assert result.session_id == "thread-codex-turn-1"
    assert result.output == %{"ok" => true}
    assert Enum.map(result.events, & &1.type) == [:turn_completed]
    assert result.metadata == %{thread_id: "thread-codex", turn_id: "turn-1"}
    assert :ok = Runtime.stop_session(session)
  end

  test "codex adapter normalizes startup and turn errors" do
    assert {:error, {:runtime_error, :missing_workspace}} =
             Runtime.start_session(Codex, %{app_server: FakeAppServer})

    assert {:error, {:runtime_error, :codex_start_failed}} =
             Runtime.start_session(Codex, %{workspace: "/tmp/fail", app_server: FakeAppServer})

    assert {:error, {:runtime_error, :codex_start_failed}} =
             Runtime.start_session(Codex, %{workspace: "/tmp/crash", app_server: FakeAppServer})

    assert {:error, {:runtime_error, :codex_start_failed}} =
             Runtime.start_session(Codex, %{workspace: "/tmp/exit", app_server: FakeAppServer})

    assert {:error, {:runtime_error, :codex_start_failed}} =
             Runtime.start_session(Codex, %{workspace: "/tmp/throw", app_server: FakeAppServer})

    assert {:error, {:runtime_error, :codex_start_failed}} =
             Runtime.start_session(Codex, %{workspace: "/tmp/bad-return", app_server: FakeAppServer})

    assert {:error, {:runtime_error, :invalid_startup_response}} =
             Runtime.start_session(Codex, %{workspace: "/tmp/malformed", app_server: FakeAppServer})

    {:ok, session} =
      Runtime.start_session(Codex, %{
        workspace: "/tmp/codex",
        app_server: FakeAppServer,
        app_server_opts: [worker: "local"]
      })

    assert {:error, {:runtime_error, :missing_prompt}} = Runtime.run_turn(session, %{})

    assert {:error, {:runtime_error, :codex_turn_failed}} =
             Runtime.run_turn(session, %{prompt: "fail"})

    assert {:error, {:runtime_error, :codex_turn_failed}} =
             Runtime.run_turn(session, %{prompt: "crash"})

    assert {:error, {:runtime_error, :codex_turn_failed}} =
             Runtime.run_turn(session, %{prompt: "exit"})

    assert {:error, {:runtime_error, :codex_turn_failed}} =
             Runtime.run_turn(session, %{prompt: "throw"})

    assert {:error, {:runtime_error, :codex_invalid_response}} =
             Runtime.run_turn(session, %{prompt: "malformed"})
  end

  test "codex adapter sanitizes AppServer stop failures" do
    for thread_id <- ["thread-stop-error", "thread-stop-raise", "thread-stop-exit", "thread-stop-bad-return"] do
      session = %Runtime.Session{
        adapter: Codex,
        runtime: :codex,
        session_id: thread_id,
        adapter_state: %{app_server: FakeAppServer, app_session: %{thread_id: thread_id}},
        metadata: %{}
      }

      assert {:error, {:runtime_error, :codex_stop_failed}} = Runtime.stop_session(session)
    end
  end

  test "runtime facade preserves error tuples and sanitizes adapter boundary failures" do
    assert {:error, {:runtime_error, :existing_start_error}} = Runtime.start_session(UnsafeAdapter, %{mode: :error})
    assert {:error, {:runtime_error, :start_session_failed}} = Runtime.start_session(UnsafeAdapter, %{mode: :raise})
    assert {:error, {:runtime_error, :start_session_failed}} = Runtime.start_session(UnsafeAdapter, %{mode: :exit})
    assert {:error, {:runtime_error, :start_session_failed}} = Runtime.start_session(UnsafeAdapter, %{mode: :throw})

    {:ok, session} = Runtime.start_session(UnsafeAdapter, %{})

    assert {:error, {:runtime_error, :existing_turn_error}} = Runtime.run_turn(session, %{mode: :error})
    assert {:error, {:runtime_error, :run_turn_failed}} = Runtime.run_turn(session, %{mode: :raise})
    assert {:error, {:runtime_error, :run_turn_failed}} = Runtime.run_turn(session, %{mode: :exit})
    assert {:error, {:runtime_error, :run_turn_failed}} = Runtime.run_turn(session, %{mode: :throw})

    assert {:error, {:runtime_error, :existing_stop_error}} = Runtime.stop_session(%{session | adapter_state: :error})
    assert {:error, {:runtime_error, :stop_session_failed}} = Runtime.stop_session(%{session | adapter_state: :raise})
    assert {:error, {:runtime_error, :stop_session_failed}} = Runtime.stop_session(%{session | adapter_state: :exit})
    assert {:error, {:runtime_error, :stop_session_failed}} = Runtime.stop_session(%{session | adapter_state: :throw})
  end

  test "runtime exposes conservative capabilities and deterministic health checks" do
    assert {:ok, simulated_capabilities} = Runtime.capabilities(Simulated, model_reference())
    assert simulated_capabilities["structured_output"] == true

    assert {:ok, simulated_health} = Runtime.health_check(Simulated, model_reference())
    assert simulated_health["runtime"] == "simulated"
    assert simulated_health["status"] == "passed"
    assert simulated_health["structured_plan_probe"]["schema"] == "passed"

    assert {:ok, codex_capabilities} = Runtime.capabilities(Codex, model_reference())
    assert codex_capabilities["structured_output"] == true

    assert {:ok, codex_health} =
             Runtime.health_check(Codex, model_reference(),
               app_server: FakeAppServer,
               app_server_opts: [worker: "local"],
               workspace: "/tmp/codex"
             )

    inspected = inspect(codex_health)

    assert codex_health["runtime"] == "codex"
    assert codex_health["status"] == "passed"
    assert codex_health["structured_plan_probe"]["mode"] == "read_only"
    refute inspected =~ "SECRET"
    refute inspected =~ "FakeAppServer"

    assert {:error, {:runtime_error, :capabilities_failed}} = Runtime.capabilities(UnsafeAdapter, %{})
    assert {:error, {:runtime_error, :health_check_failed}} = Runtime.health_check(UnsafeAdapter, %{})
  end

  test "codex health check binds configured endpoint model and brokered credential without leaking it" do
    model_reference =
      model_reference()
      |> Map.put("id", "provider-bound-model")
      |> Map.put("model_id", "configured-health-model")
      |> Map.put("endpoint", "https://models.example.test/v1")

    assert {:ok, health} =
             Runtime.health_check(Codex, model_reference,
               app_server: FakeAppServer,
               app_server_opts: [test_pid: self()],
               provider: %{
                 "id" => "configured-provider",
                 "runtime_protocol" => "codex_app_server",
                 "endpoint" => "https://models.example.test/v1",
                 "wire_api" => "responses"
               },
               provider_credential: "BROKERED_PROVIDER_SECRET",
               workspace: "/tmp/provider-bound"
             )

    assert_receive :provider_bound_stopped
    assert health["model_id"] == "configured-health-model"
    assert health["endpoint"] == "https://models.example.test/v1"
    refute inspect(health) =~ "BROKERED_PROVIDER_SECRET"
  end

  test "codex health check rejects credential-bearing provider endpoints" do
    endpoints = [
      "https://user:secret@models.example.test/v1",
      "https://models.example.test/v1?api_key=secret",
      "https://models.example.test/v1#secret"
    ]

    for endpoint <- endpoints do
      model_reference = Map.put(model_reference(), "endpoint", endpoint)

      assert {:error, {:runtime_error, :invalid_provider_binding}} =
               Runtime.health_check(Codex, model_reference,
                 provider: %{
                   "id" => "configured-provider",
                   "runtime_protocol" => "codex_app_server",
                   "endpoint" => endpoint,
                   "wire_api" => "responses"
                 },
                 provider_credential: "BROKERED_PROVIDER_SECRET"
               )
    end
  end

  test "codex health check sanitizes start, turn, invalid structured output, and stop failures" do
    assert {:error, {:runtime_error, :missing_capabilities}} = Runtime.capabilities(Codex, %{})

    assert {:error, {:runtime_error, :structured_output_unavailable}} =
             Runtime.health_check(Codex, put_in(model_reference(), ["capabilities", "structured_output"], false))

    assert {:error, {:runtime_error, :missing_model_id}} =
             Runtime.health_check(Codex, Map.delete(model_reference(), "model_id"))

    assert {:error, {:runtime_error, :missing_endpoint}} =
             Runtime.health_check(Codex, Map.delete(model_reference(), "endpoint"))

    assert {:error, {:runtime_error, :codex_health_start_failed}} =
             Runtime.health_check(Codex, model_reference(), app_server: FakeAppServer, workspace: "/tmp/fail")

    assert {:error, {:runtime_error, :codex_health_start_failed}} =
             Runtime.health_check(Codex, model_reference(), app_server: FakeAppServer, workspace: {:bad, :workspace})

    file_workspace = Path.join(System.tmp_dir!(), "symphony-runtime-health-file-#{System.unique_integer([:positive])}")
    File.write!(file_workspace, "not-a-directory")

    assert {:error, {:runtime_error, :codex_health_start_failed}} =
             Runtime.health_check(Codex, model_reference(),
               app_server: FakeAppServer,
               workspace: Path.join(file_workspace, "child")
             )

    File.rm(file_workspace)

    assert {:error, {:runtime_error, :codex_health_turn_failed}} =
             Runtime.health_check(Codex, model_reference(), app_server: FakeAppServer, workspace: "/tmp/probe-turn-fail")

    assert {:error, {:runtime_error, :codex_health_invalid_response}} =
             Runtime.health_check(Codex, model_reference(), app_server: FakeAppServer, workspace: "/tmp/probe-invalid")

    assert {:error, {:runtime_error, :codex_health_stop_failed}} =
             Runtime.health_check(Codex, model_reference(), app_server: FakeAppServer, workspace: "/tmp/probe-stop-fail")
  end

  test "runtime health checks cover fallback capability and price snapshots" do
    assert {:error, {:runtime_error, :missing_capabilities}} = Runtime.capabilities(Simulated, %{})

    simulated_without_prices = Map.delete(model_reference(), "prices")
    assert {:ok, %{"prices" => %{}}} = Runtime.health_check(Simulated, simulated_without_prices)

    codex_without_prices = Map.delete(model_reference(), "prices")

    assert {:ok, %{"prices" => %{}}} =
             Runtime.health_check(Codex, codex_without_prices,
               app_server: FakeAppServer,
               app_server_opts: [worker: "local"],
               workspace: "/tmp/codex"
             )

    assert {:ok, %{"status" => "passed"}} =
             Runtime.health_check(Codex, model_reference(),
               app_server: FakeAppServer,
               workspace: "/tmp/probe-string-result"
             )
  end

  defp model_reference do
    %{
      "id" => "simulated-model",
      "provider_id" => "simulated-provider",
      "model_id" => "simulated-codex",
      "endpoint" => "http://127.0.0.1:4010",
      "capabilities" => %{
        "structured_output" => true,
        "tool_use" => true,
        "context_window" => 128_000
      },
      "prices" => %{"input" => 0, "cached_input" => 0, "output" => 0}
    }
  end
end
