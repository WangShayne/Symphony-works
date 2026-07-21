defmodule SymphonyElixir.SourceControl.GitHub do
  @moduledoc """
  GitHub Source Control adapter. Provider-specific REST and GraphQL remain private.
  """

  @behaviour SymphonyElixir.SourceControl

  alias SymphonyElixir.SourceControl.{
    AdapterSupport,
    Baseline,
    Branch,
    ChangeRequest,
    Transport
  }

  alias SymphonyElixir.SourceControl.ChangeRequest.State

  @convert_to_draft """
  mutation ConvertToDraft($input: ConvertPullRequestToDraftInput!) {
    convertPullRequestToDraft(input: $input) {
      clientMutationId
      pullRequest { id number isDraft }
    }
  }
  """

  @mark_ready """
  mutation MarkReady($input: MarkPullRequestReadyForReviewInput!) {
    markPullRequestReadyForReview(input: $input) {
      clientMutationId
      pullRequest { id number isDraft }
    }
  }
  """

  @impl true
  def health_check(config) when is_map(config) do
    with {:ok, repository, base_branch} <- repository(config),
         {:ok, bot_actor_id} <- bot_actor_id(config),
         {:ok, repo_response} <- get(config, "/repos/#{repository}"),
         {:ok, repo} <- expect(repo_response, 200),
         {:ok, branch_response} <- get(config, "/repos/#{repository}/branches/#{segment(base_branch)}"),
         {:ok, branch} <- expect(branch_response, 200),
         {:ok, rules_response} <- get(config, "/repos/#{repository}/rules/branches/#{segment(base_branch)}"),
         true <- rules_response.status in [200, 404],
         {:ok, user_response} <- get(config, "/user"),
         {:ok, user} <- expect(user_response, 200),
         {:ok, credential_actor} <- credential_actor(user, bot_actor_id),
         commit_sha when is_binary(commit_sha) <- get_in(branch, ["commit", "sha"]),
         permissions = permissions(repo, repo_response.headers),
         :ok <- require_write_permissions(permissions) do
      {:ok,
       %{
         provider: :github,
         repository: repository,
         base_branch: base_branch,
         base_commit_sha: commit_sha,
         permissions: permissions,
         credential_actor: credential_actor,
         status: :passed
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def resolve_baseline(config, branch) when is_map(config) and is_binary(branch) do
    with {:ok, repository} <- repository_name(config),
         true <- nonempty_string?(branch),
         {:ok, response} <- get(config, "/repos/#{repository}/branches/#{segment(branch)}"),
         {:ok, body} <- expect(response, 200),
         commit_sha when is_binary(commit_sha) <- get_in(body, ["commit", "sha"]) do
      {:ok,
       %Baseline{
         provider: :github,
         repository: repository,
         branch: branch,
         commit_sha: commit_sha
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def ensure_remote_branch(config, branch, opts)
      when is_map(config) and is_map(branch) and is_list(opts) do
    with {:ok, _operation_id, _dedupe_key} <- AdapterSupport.operation_identity(opts),
         {:ok, repository} <- repository_name(config),
         name when is_binary(name) <- value(branch, :name),
         commit_sha when is_binary(commit_sha) <- value(branch, :commit_sha),
         true <- nonempty_string?(name) and nonempty_string?(commit_sha) do
      reconcile_or_create_branch(config, repository, name, commit_sha)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def push_branch(config, name, desired_sha, opts)
      when is_map(config) and is_binary(name) and is_binary(desired_sha) and is_list(opts) do
    with {:ok, _operation_id, _dedupe_key} <- AdapterSupport.operation_identity(opts),
         {:ok, repository} <- repository_name(config),
         expected_sha when is_binary(expected_sha) <- Keyword.get(opts, :expected_remote_sha),
         true <- nonempty_string?(name) and valid_sha?(desired_sha) and valid_sha?(expected_sha) do
      push_result = Transport.push(config, :github, name, desired_sha, expected_sha)
      reconcile_push(config, repository, name, desired_sha, expected_sha, push_result)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def ensure_change_request(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, operation_id, dedupe_key} <- AdapterSupport.operation_identity(opts),
         config when is_map(config) <- value(attrs, :repo),
         {:ok, repository} <- repository_name(config),
         {:ok, input} <- change_request_input(attrs),
         {:ok, existing} <- list_change_requests(config, repository),
         {:ok, decision} <- find_change_request(existing, repository, input) do
      _ = {operation_id, dedupe_key}

      case decision do
        :create ->
          create_change_request(config, repository, input)
      end
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def state(config, %ChangeRequest{number: number} = change_request)
      when is_map(config) and is_integer(number) do
    with {:ok, repository} <- repository_name(config),
         true <- repository == change_request.repository,
         {:ok, pull_response} <- get(config, "/repos/#{repository}/pulls/#{number}"),
         {:ok, pull} <- expect(pull_response, 200),
         {:ok, merge_response} <- get(config, "/repos/#{repository}/pulls/#{number}/merge"),
         true <- merge_response.status in [204, 404],
         head_sha when is_binary(head_sha) <- get_in(pull, ["head", "sha"]),
         base_branch when is_binary(base_branch) <- get_in(pull, ["base", "ref"]),
         {:ok, rules} <- required_status_rules(config, repository, base_branch),
         {:ok, checks_response} <-
           github_get(config, "/repos/#{repository}/commits/#{head_sha}/check-runs", %{
             "filter" => "latest",
             "per_page" => 100
           }),
         {:ok, checks_body} <- expect(checks_response, 200),
         {:ok, statuses_response} <-
           github_get(config, "/repos/#{repository}/commits/#{head_sha}/statuses", %{
             "per_page" => 100
           }),
         {:ok, statuses} <- expect(statuses_response, 200),
         {:ok, required_checks} <- github_required_checks(rules, checks_body, statuses) do
      merged? = merge_response.status == 204 or pull["merged"] == true or is_binary(pull["merged_at"])

      {:ok,
       %State{
         provider: :github,
         external_id: to_string(pull["id"] || change_request.external_id),
         status: github_status(pull, merged?),
         base_branch: base_branch,
         head_branch: get_in(pull, ["head", "ref"]) || change_request.head_branch,
         head_sha: head_sha,
         base_sha: get_in(pull, ["base", "sha"]),
         merge_sha: pull["merge_commit_sha"],
         draft?: pull["draft"] == true,
         ready?: pull["draft"] != true,
         merged?: merged?,
         closed?: merged? or pull["state"] == "closed",
         required_checks: required_checks,
         checks_status: checks_status(required_checks),
         mergeability: github_mergeability(pull, merged?),
         observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :provider_failure}
    end
  end

  @impl true
  def set_draft(config, %ChangeRequest{number: number} = change_request, opts)
      when is_map(config) and is_integer(number) and is_list(opts) do
    with {:ok, operation_id, _dedupe_key} <- AdapterSupport.operation_identity(opts),
         draft when is_boolean(draft) <- Keyword.get(opts, :draft),
         {:ok, repository} <- repository_name(config),
         true <- repository == change_request.repository,
         {:ok, before_response} <- get(config, "/repos/#{repository}/pulls/#{number}"),
         {:ok, before} <- expect(before_response, 200),
         :ok <- validate_pull_identity(before, change_request) do
      if before["draft"] == draft do
        normalize_change_request(
          before,
          repository,
          change_request_input_from_ref(change_request, draft),
          :reconciled
        )
      else
        mutate_github_draft(config, repository, change_request, before, draft, operation_id)
      end
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  @impl true
  def close_or_comment(config, %ChangeRequest{} = change_request, opts)
      when is_map(config) and is_list(opts) do
    with {:ok, operation_id, dedupe_key} <- AdapterSupport.operation_identity(opts),
         {:ok, repository} <- repository_name(config),
         true <- repository == change_request.repository do
      case Keyword.get(opts, :action) do
        :close -> close_change_request(config, repository, change_request)
        :comment -> comment(config, repository, change_request, operation_id, dedupe_key, opts)
        _invalid -> {:error, :invalid_configuration}
      end
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_configuration}
    end
  end

  defp get(config, path) do
    Transport.request(config, :github, %{method: :get, path: path, retry: :safe})
  end

  defp github_get(config, path, query) do
    Transport.request(config, :github, %{
      method: :get,
      path: path,
      query: query,
      retry: :safe
    })
  end

  defp reconcile_or_create_branch(config, repository, name, commit_sha) do
    path = "/repos/#{repository}/git/ref/heads/#{segment(name)}"

    case get(config, path) do
      {:ok, %{status: 200, body: body}} ->
        branch_result(repository, name, commit_sha, body, :reconciled)

      {:ok, %{status: 404}} ->
        create_branch(config, repository, name, commit_sha, path)

      {:ok, response} ->
        expect(response, 200)

      {:error, _reason} = error ->
        error
    end
  end

  defp create_branch(config, repository, name, commit_sha, reconcile_path) do
    request = %{
      method: :post,
      path: "/repos/#{repository}/git/refs",
      json: %{"ref" => "refs/heads/#{name}", "sha" => commit_sha},
      retry: :never
    }

    case Transport.request(config, :github, request) do
      {:ok, %{status: 201, body: body}} ->
        branch_result(repository, name, commit_sha, body, :created)

      {:ok, %{status: status}} when status in [409, 422, 500, 502, 503, 504] ->
        reconcile_branch(config, repository, name, commit_sha, reconcile_path)

      {:ok, response} ->
        expect(response, 201)

      {:error, _reason} ->
        reconcile_branch(config, repository, name, commit_sha, reconcile_path)
    end
  end

  defp reconcile_branch(config, repository, name, commit_sha, path) do
    case get(config, path) do
      {:ok, %{status: 200, body: body}} ->
        branch_result(repository, name, commit_sha, body, :reconciled)

      _unknown ->
        {:error, :unknown_outcome}
    end
  end

  defp branch_result(repository, name, expected_sha, body, disposition) do
    case get_in(body, ["object", "sha"]) do
      ^expected_sha ->
        {:ok,
         %Branch{
           provider: :github,
           repository: repository,
           name: name,
           commit_sha: expected_sha,
           remote_ref: "refs/heads/#{name}",
           disposition: disposition
         }}

      observed when is_binary(observed) ->
        {:error, :conflict}

      _invalid ->
        {:error, :provider_failure}
    end
  end

  defp reconcile_push(config, repository, name, desired_sha, expected_sha, push_result) do
    path = "/repos/#{repository}/git/ref/heads/#{segment(name)}"

    case get(config, path) do
      {:ok, %{status: 200, body: body}} ->
        reconcile_push_body(
          body,
          repository,
          name,
          desired_sha,
          expected_sha,
          push_result
        )

      _unknown ->
        {:error, :unknown_outcome}
    end
  end

  defp reconcile_push_body(body, repository, name, desired_sha, expected_sha, push_result) do
    case get_in(body, ["object", "sha"]) do
      ^desired_sha ->
        disposition = if push_result == :ok, do: :updated, else: :reconciled
        branch_result(repository, name, desired_sha, body, disposition)

      ^expected_sha when push_result != :ok ->
        {:error, :transport_failure}

      observed when is_binary(observed) ->
        {:error, :conflict}

      _invalid ->
        {:error, :provider_failure}
    end
  end

  defp create_change_request(config, repository, input) do
    request = %{
      method: :post,
      path: "/repos/#{repository}/pulls",
      json: %{
        "title" => input.title,
        "head" => input.head,
        "base" => input.base,
        "body" => input.body,
        "draft" => input.draft
      },
      retry: :never
    }

    case Transport.request(config, :github, request) do
      {:ok, %{status: 201, body: pull}} ->
        normalize_created_change_request(pull, repository, input)

      {:ok, %{status: status}} when status in [409, 422] or status in 500..599 ->
        {:error, :unknown_outcome}

      {:ok, response} ->
        expect(response, 201)

      {:error, _reason} ->
        {:error, :unknown_outcome}
    end
  end

  defp change_request_input(attrs) do
    input = %{
      head: value(attrs, :head),
      base: value(attrs, :base),
      title: value(attrs, :title),
      body: value(attrs, :body) || "",
      draft: value(attrs, :draft)
    }

    if Enum.all?([input.head, input.base, input.title, input.body], &is_binary/1) and
         input.draft in [true, false] and nonempty_string?(input.head) and
         nonempty_string?(input.base) and nonempty_string?(input.title) do
      {:ok, input}
    else
      {:error, :invalid_configuration}
    end
  end

  defp list_change_requests(config, repository) do
    query = %{
      "state" => "all",
      "per_page" => 100,
      "page" => 1
    }

    list_change_request_page(config, repository, query, [], 0)
  end

  defp list_change_request_page(_config, _repository, _query, _acc, pages) when pages >= 20,
    do: {:error, :provider_failure}

  defp list_change_request_page(config, repository, query, acc, pages) do
    request = %{
      method: :get,
      path: "/repos/#{repository}/pulls",
      query: query,
      retry: :safe
    }

    with {:ok, response} <- Transport.request(config, :github, request),
         {:ok, pulls} <- expect(response, 200),
         true <- is_list(pulls) do
      combined = acc ++ pulls

      case github_next_page(response.headers) do
        nil -> {:ok, combined}
        next -> list_change_request_page(config, repository, %{query | "page" => next}, combined, pages + 1)
      end
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :provider_failure}
    end
  end

  defp github_next_page(headers) do
    link = Map.get(headers, "link", "")

    case Regex.run(~r/[?&]page=(\d+)[^>]*>;\s*rel="next"/, link) do
      [_, page] -> String.to_integer(page)
      _missing -> nil
    end
  end

  defp find_change_request(pulls, repository, input) do
    cond do
      not Enum.all?(pulls, &pull_shape?(&1)) ->
        {:error, :provider_failure}

      Enum.any?(pulls, &pull_identity?(&1, repository, input)) ->
        {:error, :conflict}

      true ->
        {:ok, :create}
    end
  end

  defp pull_shape?(pull) do
    positive_integer?(pull["id"]) and positive_integer?(pull["number"]) and
      nonempty_string?(get_in(pull, ["head", "repo", "full_name"])) and
      nonempty_string?(get_in(pull, ["head", "ref"])) and
      nonempty_string?(get_in(pull, ["base", "repo", "full_name"])) and
      nonempty_string?(get_in(pull, ["base", "ref"]))
  end

  defp pull_identity?(pull, repository, input) do
    get_in(pull, ["head", "repo", "full_name"]) == repository and
      get_in(pull, ["head", "ref"]) == input.head and
      get_in(pull, ["base", "repo", "full_name"]) == repository and
      get_in(pull, ["base", "ref"]) == input.base
  end

  defp normalize_created_change_request(pull, repository, input) do
    case normalize_change_request(pull, repository, input, :created) do
      {:ok, _change_request} = ok -> ok
      {:error, _reason} -> {:error, :unknown_outcome}
    end
  end

  defp normalize_change_request(pull, repository, input, disposition) do
    external_id = pull["id"]
    number = pull["number"]

    if positive_integer?(external_id) and positive_integer?(number) and
         pull_identity?(pull, repository, input) do
      {:ok,
       %ChangeRequest{
         provider: :github,
         external_id: to_string(external_id),
         number: number,
         url: pull["html_url"],
         repository: repository,
         head_branch: get_in(pull, ["head", "ref"]) || input.head,
         base_branch: get_in(pull, ["base", "ref"]) || input.base,
         title: pull["title"] || input.title,
         draft?: pull["draft"] == true,
         disposition: disposition
       }}
    else
      {:error, :provider_failure}
    end
  end

  defp github_required_checks(rules, checks_body, statuses)
       when is_list(rules) and is_map(checks_body) and is_list(statuses) do
    with {:ok, required_rules} <- normalize_required_status_rules(rules),
         {:ok, check_runs} <- normalize_check_runs(checks_body),
         {:ok, commit_statuses} <- normalize_commit_statuses(statuses) do
      checks =
        required_rules
        |> Enum.uniq_by(&{&1.context, &1.integration_id})
        |> Enum.map(&required_check_result(&1, check_runs, commit_statuses))
        |> Enum.sort_by(& &1.name)

      {:ok, checks}
    end
  end

  defp github_required_checks(_rules, _checks_body, _statuses),
    do: {:error, :provider_failure}

  defp normalize_required_status_rules(rules) do
    Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, acc} ->
      case normalize_ruleset_rule(rule) do
        {:ok, normalized} -> {:cont, {:ok, normalized ++ acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_ruleset_rule(%{
         "type" => "required_status_checks",
         "parameters" => %{"required_status_checks" => required}
       })
       when is_list(required) do
    Enum.reduce_while(required, {:ok, []}, fn rule, {:ok, acc} ->
      case normalize_required_status_rule(rule) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_ruleset_rule(%{"type" => "required_status_checks"}),
    do: {:error, :provider_failure}

  defp normalize_ruleset_rule(rule) when is_map(rule), do: {:ok, []}
  defp normalize_ruleset_rule(_rule), do: {:error, :provider_failure}

  defp normalize_check_runs(%{"check_runs" => check_runs}) when is_list(check_runs) do
    if Enum.all?(check_runs, &valid_check_run?/1),
      do: {:ok, check_runs},
      else: {:error, :provider_failure}
  end

  defp normalize_check_runs(_checks_body), do: {:error, :provider_failure}

  defp valid_check_run?(%{"name" => name} = check_run) when is_binary(name) do
    nonempty_string?(name) and valid_optional_string?(check_run["status"]) and
      valid_optional_string?(check_run["conclusion"]) and
      valid_optional_string?(check_run["details_url"]) and valid_check_run_app?(check_run["app"])
  end

  defp valid_check_run?(_check_run), do: false

  defp valid_check_run_app?(nil), do: true
  defp valid_check_run_app?(%{"id" => id}) when is_integer(id), do: true
  defp valid_check_run_app?(_app), do: false

  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: is_binary(value)

  defp normalize_commit_statuses(statuses) do
    Enum.reduce_while(statuses, {:ok, %{}}, fn
      %{"context" => name} = status, {:ok, acc} when is_binary(name) ->
        if nonempty_string?(name) do
          normalized = %{
            name: name,
            status: github_commit_status(status["state"]),
            url: status["target_url"]
          }

          {:cont, {:ok, Map.put_new(acc, name, normalized)}}
        else
          {:halt, {:error, :provider_failure}}
        end

      _status, _acc ->
        {:halt, {:error, :provider_failure}}
    end)
  end

  defp required_status_rules(config, repository, base_branch) do
    rules_path = "/repos/#{repository}/rules/branches/#{segment(base_branch)}"

    case get(config, rules_path) do
      {:ok, %{status: 200, body: []}} ->
        required_status_rules_from_protection(config, repository, base_branch)

      {:ok, %{status: 200, body: rules}} when is_list(rules) ->
        {:ok, rules}

      {:ok, %{status: 404}} ->
        required_status_rules_from_protection(config, repository, base_branch)

      {:ok, response} ->
        expect(response, 200)

      {:error, _reason} = error ->
        error
    end
  end

  defp required_status_rules_from_protection(config, repository, base_branch) do
    path =
      "/repos/#{repository}/branches/#{segment(base_branch)}/protection/required_status_checks"

    case get(config, path) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        normalize_protection_rules(body)

      {:ok, %{status: 404}} ->
        {:ok, []}

      {:ok, response} ->
        expect(response, 200)

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_protection_rules(body) do
    checks = Map.get(body, "checks", [])
    contexts = Map.get(body, "contexts", [])

    if is_list(checks) and is_list(contexts) and
         Enum.all?(checks, &valid_protection_check?/1) and
         Enum.all?(contexts, &nonempty_string?/1) do
      checked_contexts = checks |> Enum.map(& &1["context"]) |> MapSet.new()

      legacy_contexts =
        contexts
        |> Enum.reject(&MapSet.member?(checked_contexts, &1))
        |> Enum.map(&%{"context" => &1, "integration_id" => nil})

      app_checks =
        Enum.map(checks, fn check ->
          %{"context" => check["context"], "integration_id" => check["app_id"]}
        end)

      {:ok,
       [
         %{
           "type" => "required_status_checks",
           "parameters" => %{"required_status_checks" => legacy_contexts ++ app_checks}
         }
       ]}
    else
      {:error, :provider_failure}
    end
  end

  defp valid_protection_check?(%{"context" => context} = check)
       when is_binary(context) do
    app_id = check["app_id"]
    nonempty_string?(context) and (is_nil(app_id) or is_integer(app_id))
  end

  defp valid_protection_check?(_check), do: false

  defp github_check_run_status(%{"status" => status}) when status in ["queued", "in_progress"],
    do: :pending

  defp github_check_run_status(%{"conclusion" => "success"}), do: :passed

  defp github_check_run_status(%{"conclusion" => conclusion})
       when conclusion in ["failure", "cancelled", "timed_out", "action_required", "stale"],
       do: :failed

  defp github_check_run_status(_check), do: :unknown

  defp normalize_required_status_rule(%{"context" => context} = rule)
       when is_binary(context) do
    integration_id = rule["integration_id"] || rule["app_id"]

    if nonempty_string?(context) and (is_nil(integration_id) or is_integer(integration_id)) do
      {:ok, %{context: context, integration_id: integration_id}}
    else
      {:error, :provider_failure}
    end
  end

  defp normalize_required_status_rule(_rule), do: {:error, :provider_failure}

  defp required_check_result(rule, check_runs, commit_statuses) do
    check_run =
      Enum.find(check_runs, fn check ->
        check["name"] == rule.context and
          (is_nil(rule.integration_id) or check_run_app_id(check) == rule.integration_id)
      end)

    if is_map(check_run) do
      %{
        name: rule.context,
        status: github_check_run_status(check_run),
        url: check_run["details_url"]
      }
    else
      if is_nil(rule.integration_id) do
        Map.get(commit_statuses, rule.context) || pending_required_check(rule.context)
      else
        pending_required_check(rule.context)
      end
    end
  end

  defp check_run_app_id(%{"app" => %{"id" => id}}), do: id
  defp check_run_app_id(_check_run), do: nil

  defp pending_required_check(name), do: %{name: name, status: :pending, url: nil}

  defp github_commit_status("success"), do: :passed
  defp github_commit_status("pending"), do: :pending
  defp github_commit_status(state) when state in ["failure", "error"], do: :failed
  defp github_commit_status(_state), do: :unknown

  defp checks_status([]), do: :passed

  defp checks_status(checks) do
    if Enum.any?(checks, &(&1.status == :failed)) do
      :failed
    else
      if Enum.any?(checks, &(&1.status in [:pending, :unknown])), do: :pending, else: :passed
    end
  end

  defp github_status(_pull, true), do: :merged
  defp github_status(%{"state" => "closed"}, false), do: :closed
  defp github_status(_pull, false), do: :open

  defp github_mergeability(_pull, true), do: :mergeable
  defp github_mergeability(%{"mergeable" => nil}, false), do: :checking

  defp github_mergeability(%{"mergeable" => false, "mergeable_state" => "dirty"}, false),
    do: :conflicting

  defp github_mergeability(%{"mergeable" => false}, false), do: :blocked

  defp github_mergeability(%{"mergeable" => true, "mergeable_state" => state}, false)
       when state in ["blocked", "behind", "unstable"] do
    :blocked
  end

  defp github_mergeability(%{"mergeable" => true}, false), do: :mergeable
  defp github_mergeability(_pull, false), do: :unknown

  defp mutate_github_draft(
         config,
         repository,
         change_request,
         before,
         draft,
         operation_id
       ) do
    node_id = before["node_id"]

    if nonempty_string?(node_id) do
      {query, result_key} =
        if draft,
          do: {@convert_to_draft, "convertPullRequestToDraft"},
          else: {@mark_ready, "markPullRequestReadyForReview"}

      request = %{
        method: :post,
        path: "/graphql",
        json: %{
          "query" => query,
          "variables" => %{
            "input" => %{
              "pullRequestId" => node_id,
              "clientMutationId" => operation_id
            }
          }
        },
        retry: :never
      }

      mutation_result = Transport.request(config, :github, request)
      mutation_applied? = github_mutation_applied?(mutation_result, result_key, draft)

      reconcile_github_draft(
        config,
        repository,
        change_request,
        draft,
        mutation_applied?
      )
    else
      {:error, :provider_failure}
    end
  end

  defp github_mutation_applied?(
         {:ok, %{status: 200, body: %{"data" => data} = body}},
         result_key,
         draft
       )
       when is_map(data) do
    not Map.has_key?(body, "errors") and
      get_in(data, [result_key, "pullRequest", "isDraft"]) == draft
  end

  defp github_mutation_applied?(_result, _result_key, _draft), do: false

  defp reconcile_github_draft(config, repository, change_request, draft, mutation_applied?) do
    path = "/repos/#{repository}/pulls/#{change_request.number}"

    with {:ok, response} <- get(config, path),
         {:ok, pull} <- expect(response, 200),
         :ok <- validate_pull_identity(pull, change_request) do
      github_draft_reconciliation(
        pull,
        repository,
        change_request,
        draft,
        mutation_applied?
      )
    else
      _unknown -> {:error, :unknown_outcome}
    end
  end

  defp github_draft_reconciliation(pull, repository, change_request, draft, mutation_applied?) do
    if pull["draft"] == draft do
      disposition = if mutation_applied?, do: :updated, else: :reconciled

      normalize_change_request(
        pull,
        repository,
        change_request_input_from_ref(change_request, draft),
        disposition
      )
    else
      if mutation_applied? do
        {:error, :provider_failure}
      else
        {:error, :transport_failure}
      end
    end
  end

  defp validate_pull_identity(pull, change_request) do
    if get_in(pull, ["head", "ref"]) == change_request.head_branch and
         get_in(pull, ["base", "ref"]) == change_request.base_branch do
      :ok
    else
      {:error, :conflict}
    end
  end

  defp change_request_input_from_ref(change_request, draft) do
    %{
      head: change_request.head_branch,
      base: change_request.base_branch,
      title: change_request.title,
      body: "",
      draft: draft
    }
  end

  defp close_change_request(config, repository, change_request) do
    path = "/repos/#{repository}/pulls/#{change_request.number}"

    with {:ok, before_response} <- get(config, path),
         {:ok, before} <- expect(before_response, 200),
         :ok <- validate_pull_identity(before, change_request) do
      github_close_decision(config, path, change_request, before)
    end
  end

  defp github_close_decision(_config, _path, _change_request, %{"merged" => true} = before) do
    {:ok, %{action: :already_applied, external_id: to_string(before["id"])}}
  end

  defp github_close_decision(
         _config,
         _path,
         _change_request,
         %{"merged_at" => merged_at} = before
       )
       when is_binary(merged_at) do
    {:ok, %{action: :already_applied, external_id: to_string(before["id"])}}
  end

  defp github_close_decision(_config, _path, _change_request, %{"state" => "closed"} = before) do
    {:ok, %{action: :already_applied, external_id: to_string(before["id"])}}
  end

  defp github_close_decision(config, path, change_request, _before) do
    request = %{method: :patch, path: path, json: %{"state" => "closed"}, retry: :never}
    mutation_applied? = match?({:ok, %{status: 200}}, Transport.request(config, :github, request))
    reconcile_closed_pull(config, path, change_request, mutation_applied?)
  end

  defp reconcile_closed_pull(config, path, change_request, mutation_applied?) do
    with {:ok, response} <- get(config, path),
         {:ok, pull} <- expect(response, 200),
         :ok <- validate_pull_identity(pull, change_request) do
      closed_pull_reconciliation(pull, change_request, mutation_applied?)
    else
      _unknown -> {:error, :unknown_outcome}
    end
  end

  defp closed_pull_reconciliation(pull, change_request, mutation_applied?) do
    if pull["state"] == "closed" or pull["merged"] == true do
      action = if mutation_applied?, do: :closed, else: :already_applied
      {:ok, %{action: action, external_id: to_string(pull["id"] || change_request.external_id)}}
    else
      {:error, if(mutation_applied?, do: :provider_failure, else: :transport_failure)}
    end
  end

  defp comment(config, repository, change_request, operation_id, dedupe_key, opts) do
    case Keyword.get(opts, :body) do
      body when is_binary(body) ->
        comment_with_body(config, repository, change_request, operation_id, dedupe_key, body)

      _invalid ->
        {:error, :invalid_configuration}
    end
  end

  defp comment_with_body(
         config,
         repository,
         %ChangeRequest{} = change_request,
         operation_id,
         dedupe_key,
         body
       )
       when is_binary(repository) and is_binary(operation_id) and is_binary(dedupe_key) and
              is_binary(body) do
    with true <- nonempty_string?(body),
         {:ok, bot_actor_id} <- bot_actor_id(config),
         {:ok, marker} <- comment_marker(repository, change_request, operation_id, dedupe_key, body),
         {:ok, comments} <- list_comments(config, repository, change_request.number),
         {:ok, decision} <- AdapterSupport.marker_decision(comments, "body", marker, ["user", "id"], bot_actor_id) do
      github_comment_decision(
        decision,
        config,
        repository,
        change_request,
        body,
        marker,
        bot_actor_id
      )
    else
      false -> {:error, :invalid_configuration}
      {:error, _reason} = error -> error
    end
  end

  defp comment_marker(
         repository,
         %ChangeRequest{external_id: parent_external_id},
         operation_id,
         dedupe_key,
         body
       )
       when is_binary(repository) and is_binary(parent_external_id) and is_binary(operation_id) and
              is_binary(dedupe_key) and is_binary(body) do
    # The credential is process-scoped, which Dialyzer cannot follow through
    # the adapter callback boundary.
    apply(AdapterSupport, :comment_marker, [
      :github,
      repository,
      parent_external_id,
      operation_id,
      dedupe_key,
      body
    ])
  end

  defp comment_marker(_repository, _change_request, _operation_id, _dedupe_key, _body),
    do: {:error, :invalid_configuration}

  defp github_comment_decision({:found, found}, _config, _repo, _cr, _body, _marker, _bot_actor_id) do
    {:ok, %{action: :already_applied, external_id: to_string(found["id"])}}
  end

  defp github_comment_decision(:create, config, repository, cr, body, marker, bot_actor_id) do
    create_comment(config, repository, cr, body, marker, bot_actor_id)
  end

  defp create_comment(config, repository, change_request, body, marker, bot_actor_id) do
    path = "/repos/#{repository}/issues/#{change_request.number}/comments"

    request = %{
      method: :post,
      path: path,
      json: %{"body" => AdapterSupport.append_marker(body, marker.exact)},
      retry: :never
    }

    case Transport.request(config, :github, request) do
      {:ok, %{status: 201, body: comment}} ->
        {:ok, %{action: :commented, external_id: to_string(comment["id"])}}

      {:ok, %{status: status}} when status in [409, 422, 500, 502, 503, 504] ->
        reconcile_comment(config, repository, change_request.number, marker, bot_actor_id)

      {:ok, response} ->
        expect(response, 201)

      {:error, _reason} ->
        reconcile_comment(config, repository, change_request.number, marker, bot_actor_id)
    end
  end

  defp reconcile_comment(config, repository, number, marker, bot_actor_id) do
    with {:ok, comments} <- list_comments(config, repository, number),
         {:ok, {:found, found}} <-
           AdapterSupport.marker_decision(comments, "body", marker, ["user", "id"], bot_actor_id) do
      {:ok, %{action: :already_applied, external_id: to_string(found["id"])}}
    else
      {:ok, :create} -> {:error, :unknown_outcome}
      {:error, _reason} = error -> error
    end
  end

  defp list_comments(config, repository, number) do
    list_comment_page(config, repository, number, %{"per_page" => 100, "page" => 1}, [], 0)
  end

  defp list_comment_page(_config, _repository, _number, _query, _acc, pages) when pages >= 20,
    do: {:error, :provider_failure}

  defp list_comment_page(config, repository, number, query, acc, pages) do
    request = %{
      method: :get,
      path: "/repos/#{repository}/issues/#{number}/comments",
      query: query,
      retry: :safe
    }

    with {:ok, response} <- Transport.request(config, :github, request),
         {:ok, comments} <- expect(response, 200),
         true <- is_list(comments) do
      combined = acc ++ comments

      case github_next_page(response.headers) do
        nil -> {:ok, combined}
        next -> list_comment_page(config, repository, number, %{query | "page" => next}, combined, pages + 1)
      end
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :provider_failure}
    end
  end

  defp expect(%{status: status, body: body}, status), do: {:ok, body}
  defp expect(%{status: 401}, _expected), do: {:error, :unauthorized}
  defp expect(%{status: 403}, _expected), do: {:error, :forbidden}
  defp expect(%{status: 404}, _expected), do: {:error, :not_found}
  defp expect(_response, _expected), do: {:error, :provider_failure}

  defp repository(config) do
    settings = value(config, :settings) || %{}
    repository = value(settings, :repository)
    base_branch = value(settings, :base_branch)

    if valid_repository?(repository) and nonempty_string?(base_branch) do
      {:ok, repository, base_branch}
    else
      {:error, :invalid_configuration}
    end
  end

  defp repository_name(config) do
    settings = value(config, :settings) || %{}
    repository = value(settings, :repository)

    if valid_repository?(repository),
      do: {:ok, repository},
      else: {:error, :invalid_configuration}
  end

  defp bot_actor_id(config) do
    settings = value(config, :settings) || %{}
    actor_id = value(settings, :bot_actor_id)

    if canonical_actor_id?(actor_id),
      do: {:ok, String.trim(actor_id)},
      else: {:error, :invalid_configuration}
  end

  defp credential_actor(user, bot_actor_id) do
    actor_id = Map.get(user, "id")

    cond do
      not (is_integer(actor_id) and actor_id > 0) ->
        {:error, :invalid_configuration}

      Integer.to_string(actor_id) != bot_actor_id ->
        {:error, :forbidden}

      true ->
        {:ok, %{id: bot_actor_id, matched?: true}}
    end
  end

  defp canonical_actor_id?(value) when is_binary(value), do: Regex.match?(~r/\A[1-9][0-9]*\z/, value)
  defp canonical_actor_id?(_value), do: false

  defp permissions(repo, headers) do
    repo_permissions = repo["permissions"] || %{}
    push = tri_state(repo_permissions["push"])
    scopes = Map.get(headers, "x-oauth-scopes", "")

    change_request =
      if "repo" in (scopes |> String.split(",") |> Enum.map(&String.trim/1)) do
        :allowed
      else
        if push == :denied, do: :denied, else: :unknown
      end

    %{
      repository_read: :allowed,
      branch_write: push,
      change_request_write: change_request
    }
  end

  defp require_write_permissions(%{
         branch_write: :allowed,
         change_request_write: :allowed
       }),
       do: :ok

  defp require_write_permissions(_permissions), do: {:error, :forbidden}

  defp tri_state(true), do: :allowed
  defp tri_state(false), do: :denied
  defp tri_state(_unknown), do: :unknown

  defp valid_repository?(repository) when is_binary(repository) do
    case String.split(repository, "/") do
      [owner, name] -> nonempty_string?(owner) and nonempty_string?(name)
      _other -> false
    end
  end

  defp valid_repository?(_repository), do: false

  defp segment(value), do: URI.encode_www_form(value)
  defp nonempty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_string?(_value), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_sha?(sha) when is_binary(sha), do: Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, sha)

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
