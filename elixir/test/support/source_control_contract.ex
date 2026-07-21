defmodule SymphonyElixir.SourceControlContract do
  @moduledoc false

  use ExUnit.CaseTemplate

  using options do
    adapter = Keyword.fetch!(options, :adapter)

    quote do
      @source_control_adapter unquote(adapter)
      @source_control_callbacks MapSet.new([
                                  {:health_check, 1},
                                  {:resolve_baseline, 2},
                                  {:ensure_remote_branch, 3},
                                  {:push_branch, 4},
                                  {:ensure_change_request, 2},
                                  {:set_draft, 3},
                                  {:state, 2},
                                  {:close_or_comment, 3}
                                ])

      test "implements the complete provider-neutral Source Control contract" do
        callbacks = MapSet.new(SymphonyElixir.SourceControl.behaviour_info(:callbacks))

        assert callbacks == @source_control_callbacks

        assert Enum.all?(@source_control_callbacks, fn {name, arity} ->
                 function_exported?(@source_control_adapter, name, arity)
               end)

        refute function_exported?(@source_control_adapter, :merge_change_request, 3)
      end

      test "rejects every mutation without the complete operation identity" do
        change_request = %SymphonyElixir.SourceControl.ChangeRequest{
          provider: :fixture,
          external_id: "contract-change-request",
          number: 1,
          repository: "contract/repository",
          head_branch: "contract/head",
          base_branch: "main",
          draft?: true,
          disposition: :reconciled
        }

        mutations = [
          &@source_control_adapter.ensure_remote_branch(%{}, %{}, &1),
          &@source_control_adapter.push_branch(
            %{},
            "branch",
            String.duplicate("a", 40),
            &1
          ),
          &@source_control_adapter.ensure_change_request(%{}, &1),
          &@source_control_adapter.set_draft(%{}, change_request, &1),
          &@source_control_adapter.close_or_comment(%{}, change_request, &1)
        ]

        incomplete_identities = [
          [],
          [operation_id: "contract-operation"],
          [dedupe_key: "contract-dedupe"],
          [operation_id: "", dedupe_key: "contract-dedupe"],
          [operation_id: "contract-operation", dedupe_key: " "]
        ]

        for mutation <- mutations, opts <- incomplete_identities do
          assert {:error, :missing_operation_identity} = mutation.(opts)
        end
      end

      test "rejects missing repository configuration consistently" do
        assert {:error, :invalid_configuration} = @source_control_adapter.health_check(%{})

        assert {:error, :invalid_configuration} =
                 @source_control_adapter.resolve_baseline(%{}, "main")
      end
    end
  end
end

defmodule SymphonyElixir.SourceControlContract.FixtureTransport do
  @moduledoc false

  @spec start_link(Path.t()) :: Agent.on_start()
  def start_link(path) do
    responses = path |> File.read!() |> Jason.decode!()
    Agent.start_link(fn -> %{responses: responses, requests: []} end)
  end

  @spec request(map(), pid()) :: {:ok, map()} | {:error, term()}
  def request(request, agent) do
    Agent.get_and_update(agent, fn state ->
      case take_response(state.responses, request) do
        {:ok, response, remaining} ->
          {fixture_result(response, state.requests),
           %{
             state
             | responses: remaining,
               requests: state.requests ++ [request]
           }}

        :error ->
          {{:error, :no_fixture_response}, %{state | requests: state.requests ++ [request]}}
      end
    end)
  end

  @spec requests(pid()) :: [map()]
  def requests(agent), do: Agent.get(agent, & &1.requests)

  defp take_response(responses, request) do
    method = request.method |> Atom.to_string() |> String.upcase()
    index = Enum.find_index(responses, &(&1["method"] == method and &1["path"] == request.path))

    if is_integer(index) do
      {response, remaining} = List.pop_at(responses, index)
      {:ok, response, remaining}
    else
      :error
    end
  end

  defp fixture_result(%{"error" => _error}, _requests), do: {:error, :fixture_transport_failure}

  defp fixture_result(response, requests) do
    {:ok, normalize_response(response, requests)}
  end

  defp normalize_response(response, requests) do
    %{
      status: response["status"],
      headers: response["headers"] || %{},
      body: resolve_placeholders(response["body"], requests)
    }
  end

  defp resolve_placeholders("{{last_mutation_body}}", requests) do
    requests
    |> Enum.reverse()
    |> Enum.find_value(fn request ->
      if request.method in [:post, :put, :patch] do
        get_in(request, [:json, "body"]) || get_in(request, [:json, "description"])
      end
    end)
  end

  defp resolve_placeholders(value, requests) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, resolve_placeholders(item, requests)} end)
  end

  defp resolve_placeholders(value, requests) when is_list(value) do
    Enum.map(value, &resolve_placeholders(&1, requests))
  end

  defp resolve_placeholders(value, _requests), do: value
end

defmodule SymphonyElixir.SourceControlContract.ExplodingTransport do
  @moduledoc false

  @spec request(map(), term()) :: no_return()
  def request(_request, _state), do: raise("github-secret-value credential_ref=00000000-secret")
end
