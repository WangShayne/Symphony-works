defmodule SymphonyElixir.SourceControl.GitLab do
  @moduledoc """
  GitLab Source Control adapter with provider-private REST conventions.
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

  @impl true
  def health_check(config) when is_map(config) do
    with {:ok, repository, base_branch} <- repository(config),
         project = segment(repository),
         {:ok, project_response} <- get(config, "/projects/#{project}"),
         {:ok, project_body} <- expect(project_response, 200),
         {:ok, branch_response} <-
           get(config, "/projects/#{project}/repository/branches/#{segment(base_branch)}"),
         {:ok, branch} <- expect(branch_response, 200),
         {:ok, protected_response} <-
           get(config, "/projects/#{project}/protected_branches/#{segment(base_branch)}"),
         true <- protected_response.status in [200, 404],
         commit_sha when is_binary(commit_sha) <- get_in(branch, ["commit", "id"]),
         permissions = permissions(project_body, branch),
         :ok <- require_write_permissions(permissions) do
      {:ok,
       %{
         provider: :gitlab,
         repository: repository,
         base_branch: base_branch,
         base_commit_sha: commit_sha,
         permissions: permissions,
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
         project = segment(repository),
         {:ok, response} <-
           get(config, "/projects/#{project}/repository/branches/#{segment(branch)}"),
         {:ok, body} <- expect(response, 200),
         commit_sha when is_binary(commit_sha) <- get_in(body, ["commit", "id"]) do
      {:ok,
       %Baseline{
         provider: :gitlab,
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
      push_result = Transport.push(config, :gitlab, name, desired_sha, expected_sha)
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
         marker <- change_request_marker(repository, operation_id, dedupe_key, input),
         {:ok, existing} <- list_change_requests(config, repository),
         {:ok, decision} <- find_change_request(existing, input, marker) do
      case decision do
        {:found, merge_request} ->
          normalize_change_request(merge_request, repository, input, :reconciled)

        :create ->
          create_change_request(config, repository, input, marker)
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
         project = segment(repository),
         {:ok, merge_request_response} <-
           gitlab_get(config, "/projects/#{project}/merge_requests/#{number}", %{
             "with_merge_status_recheck" => true
           }),
         {:ok, merge_request} <- expect(merge_request_response, 200),
         head_sha when is_binary(head_sha) <- merge_request["sha"],
         {:ok, project_response} <- get(config, "/projects/#{project}"),
         {:ok, project_body} <- expect(project_response, 200),
         {:ok, pipelines_response} <-
           gitlab_get(config, "/projects/#{project}/merge_requests/#{number}/pipelines", %{
             "per_page" => 100
           }),
         {:ok, pipelines} <- expect(pipelines_response, 200),
         {:ok, status_checks_response} <-
           get(config, "/projects/#{project}/merge_requests/#{number}/status_checks") do
      with {:ok, required_checks} <-
             gitlab_required_checks(
               project_body,
               pipelines,
               status_checks_response,
               head_sha
             ) do
        merged? = merge_request["state"] == "merged" or is_binary(merge_request["merged_at"])

        {:ok,
         %State{
           provider: :gitlab,
           external_id: to_string(merge_request["id"] || change_request.external_id),
           status: gitlab_status(merge_request),
           base_branch: merge_request["target_branch"] || change_request.base_branch,
           head_branch: merge_request["source_branch"] || change_request.head_branch,
           head_sha: head_sha,
           base_sha: get_in(merge_request, ["diff_refs", "base_sha"]),
           merge_sha: merge_request["merge_commit_sha"],
           draft?: merge_request["draft"] == true,
           ready?: merge_request["draft"] != true,
           merged?: merged?,
           closed?: merged? or merge_request["state"] == "closed",
           required_checks: required_checks,
           checks_status: checks_status(required_checks),
           mergeability: gitlab_mergeability(merge_request["detailed_merge_status"]),
           observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
         }}
      end
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :provider_failure}
    end
  end

  @impl true
  def set_draft(config, %ChangeRequest{number: number} = change_request, opts)
      when is_map(config) and is_integer(number) and is_list(opts) do
    with {:ok, _operation_id, _dedupe_key} <- AdapterSupport.operation_identity(opts),
         draft when is_boolean(draft) <- Keyword.get(opts, :draft),
         {:ok, repository} <- repository_name(config),
         true <- repository == change_request.repository,
         {:ok, before_response} <-
           get(config, "/projects/#{segment(repository)}/merge_requests/#{number}"),
         {:ok, before} <- expect(before_response, 200),
         :ok <- validate_merge_request_identity(before, change_request) do
      if before["draft"] == draft do
        normalize_change_request(
          before,
          repository,
          change_request_input_from_ref(change_request, draft),
          :reconciled
        )
      else
        mutate_gitlab_draft(config, repository, change_request, draft)
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
    Transport.request(config, :gitlab, %{method: :get, path: path, retry: :safe})
  end

  defp gitlab_get(config, path, query) do
    Transport.request(config, :gitlab, %{
      method: :get,
      path: path,
      query: query,
      retry: :safe
    })
  end

  defp reconcile_or_create_branch(config, repository, name, commit_sha) do
    project = segment(repository)
    path = "/projects/#{project}/repository/branches/#{segment(name)}"

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
    project = segment(repository)

    request = %{
      method: :post,
      path: "/projects/#{project}/repository/branches",
      json: %{"branch" => name, "ref" => commit_sha},
      retry: :never
    }

    case Transport.request(config, :gitlab, request) do
      {:ok, %{status: 201, body: body}} ->
        branch_result(repository, name, commit_sha, body, :created)

      {:ok, %{status: status}} when status in [400, 409, 500, 502, 503, 504] ->
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
    case get_in(body, ["commit", "id"]) do
      ^expected_sha ->
        {:ok,
         %Branch{
           provider: :gitlab,
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
    path = "/projects/#{segment(repository)}/repository/branches/#{segment(name)}"

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
    case get_in(body, ["commit", "id"]) do
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

  defp create_change_request(config, repository, input, marker) do
    title = if input.draft, do: draft_title(input.title), else: input.title

    request = %{
      method: :post,
      path: "/projects/#{segment(repository)}/merge_requests",
      json: %{
        "source_branch" => input.head,
        "target_branch" => input.base,
        "title" => title,
        "description" => AdapterSupport.append_marker(input.body, marker.exact)
      },
      retry: :never
    }

    case Transport.request(config, :gitlab, request) do
      {:ok, %{status: 201, body: merge_request}} ->
        normalize_change_request(merge_request, repository, input, :created)

      {:ok, %{status: status}} when status in [400, 409, 500, 502, 503, 504] ->
        reconcile_change_request(config, repository, input, marker)

      {:ok, response} ->
        expect(response, 201)

      {:error, _reason} ->
        reconcile_change_request(config, repository, input, marker)
    end
  end

  defp reconcile_change_request(config, repository, input, marker) do
    with {:ok, merge_requests} <- list_change_requests(config, repository),
         {:ok, {:found, merge_request}} <- find_change_request(merge_requests, input, marker) do
      normalize_change_request(merge_request, repository, input, :reconciled)
    else
      {:ok, :create} -> {:error, :unknown_outcome}
      {:error, _reason} = error -> error
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

  defp change_request_marker(repository, operation_id, dedupe_key, input) do
    AdapterSupport.operation_marker(
      :gitlab,
      repository,
      :ensure_change_request,
      operation_id,
      dedupe_key,
      [input.head, input.base, input.title, AdapterSupport.body_digest(input.body), input.draft]
    )
  end

  defp list_change_requests(config, repository) do
    query = %{
      "scope" => "all",
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
      path: "/projects/#{segment(repository)}/merge_requests",
      query: query,
      retry: :safe
    }

    with {:ok, response} <- Transport.request(config, :gitlab, request),
         {:ok, merge_requests} <- expect(response, 200),
         true <- is_list(merge_requests) do
      combined = acc ++ merge_requests

      case gitlab_next_page(response.headers) do
        nil -> {:ok, combined}
        next -> list_change_request_page(config, repository, %{query | "page" => next}, combined, pages + 1)
      end
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :provider_failure}
    end
  end

  defp gitlab_next_page(headers) do
    case Integer.parse(Map.get(headers, "x-next-page", "")) do
      {page, ""} when page > 0 -> page
      _missing -> nil
    end
  end

  defp find_change_request(merge_requests, input, marker) do
    case AdapterSupport.marker_decision(merge_requests, "description", marker) do
      {:ok, {:found, merge_request}} ->
        if merge_request_identity?(merge_request, input),
          do: {:ok, {:found, merge_request}},
          else: {:error, :idempotency_conflict}

      {:ok, :create} ->
        if Enum.any?(merge_requests, &merge_request_identity?(&1, input)),
          do: {:error, :conflict},
          else: {:ok, :create}

      {:error, _reason} = error ->
        error
    end
  end

  defp merge_request_identity?(merge_request, input) do
    merge_request["source_branch"] == input.head and merge_request["target_branch"] == input.base
  end

  defp normalize_change_request(merge_request, repository, input, disposition) do
    external_id = merge_request["id"]
    number = merge_request["iid"]

    if (is_integer(external_id) or is_binary(external_id)) and is_integer(number) do
      {:ok,
       %ChangeRequest{
         provider: :gitlab,
         external_id: to_string(external_id),
         number: number,
         url: merge_request["web_url"],
         repository: repository,
         head_branch: merge_request["source_branch"] || input.head,
         base_branch: merge_request["target_branch"] || input.base,
         title: merge_request["title"] || input.title,
         draft?: merge_request["draft"] == true,
         disposition: disposition
       }}
    else
      {:error, :provider_failure}
    end
  end

  defp draft_title(title) do
    if Regex.match?(~r/\A(?:draft|wip)\s*:/i, title), do: title, else: "Draft: #{title}"
  end

  defp gitlab_required_checks(project, pipelines, status_checks_response, head_sha) do
    pipeline_checks =
      if project["only_allow_merge_if_pipeline_succeeds"] == true do
        pipeline = Enum.find(pipelines, &(&1["sha"] == head_sha))

        [
          %{
            name: "pipeline",
            status: gitlab_pipeline_status(pipeline && pipeline["status"], project),
            url: pipeline && pipeline["web_url"]
          }
        ]
      else
        []
      end

    with {:ok, external_checks} <- gitlab_external_checks(project, status_checks_response) do
      {:ok, (pipeline_checks ++ external_checks) |> Enum.sort_by(& &1.name)}
    end
  end

  defp gitlab_external_checks(
         %{"only_allow_merge_if_all_status_checks_passed" => true},
         %{status: 200, body: checks}
       )
       when is_list(checks) do
    {:ok,
     Enum.map(checks, fn check ->
       %{
         name: check["name"] || get_in(check, ["external_status_check", "name"]) || "external",
         status: gitlab_external_check_status(check["status"]),
         url: check["external_url"]
       }
     end)}
  end

  defp gitlab_external_checks(
         %{"only_allow_merge_if_all_status_checks_passed" => true},
         response
       ) do
    case expect(response, 200) do
      {:error, _reason} = error -> error
      {:ok, _invalid_body} -> {:error, :provider_failure}
    end
  end

  defp gitlab_external_checks(_project, _response), do: {:ok, []}

  defp gitlab_pipeline_status(nil, _project), do: :pending
  defp gitlab_pipeline_status("success", _project), do: :passed

  defp gitlab_pipeline_status("skipped", %{"allow_merge_on_skipped_pipeline" => true}),
    do: :passed

  defp gitlab_pipeline_status(status, _project)
       when status in ["created", "waiting_for_resource", "preparing", "pending", "running", "manual"],
       do: :pending

  defp gitlab_pipeline_status(status, _project)
       when status in ["failed", "canceled", "skipped"],
       do: :failed

  defp gitlab_pipeline_status(_status, _project), do: :unknown

  defp gitlab_external_check_status(status) when status in ["passed", "success"], do: :passed
  defp gitlab_external_check_status(status) when status in ["pending", "running"], do: :pending
  defp gitlab_external_check_status(status) when status in ["failed", "failure"], do: :failed
  defp gitlab_external_check_status(_status), do: :unknown

  defp checks_status([]), do: :passed

  defp checks_status(checks) do
    if Enum.any?(checks, &(&1.status == :failed)) do
      :failed
    else
      if Enum.any?(checks, &(&1.status in [:pending, :unknown])), do: :pending, else: :passed
    end
  end

  defp gitlab_status(%{"state" => "merged"}), do: :merged
  defp gitlab_status(%{"state" => "closed"}), do: :closed
  defp gitlab_status(_merge_request), do: :open

  defp gitlab_mergeability(status) when status in ["checking", "approvals_syncing", "preparing"],
    do: :checking

  defp gitlab_mergeability("mergeable"), do: :mergeable
  defp gitlab_mergeability("conflict"), do: :conflicting

  defp gitlab_mergeability(status)
       when status in [
              "not_open",
              "draft_status",
              "ci_must_pass",
              "ci_still_running",
              "not_approved",
              "discussions_not_resolved",
              "status_checks_must_pass",
              "blocked_status"
            ],
       do: :blocked

  defp gitlab_mergeability(_status), do: :unknown

  defp mutate_gitlab_draft(config, repository, change_request, draft) do
    request = %{
      method: :post,
      path: "/projects/#{segment(repository)}/merge_requests/#{change_request.number}/notes",
      json: %{"body" => if(draft, do: "/draft", else: "/ready")},
      retry: :never
    }

    mutation_applied? =
      case Transport.request(config, :gitlab, request) do
        {:ok, %{status: 201}} -> true
        _unknown -> false
      end

    reconcile_gitlab_draft(
      config,
      repository,
      change_request,
      draft,
      mutation_applied?
    )
  end

  defp reconcile_gitlab_draft(config, repository, change_request, draft, mutation_applied?) do
    path = "/projects/#{segment(repository)}/merge_requests/#{change_request.number}"

    with {:ok, response} <- get(config, path),
         {:ok, merge_request} <- expect(response, 200),
         :ok <- validate_merge_request_identity(merge_request, change_request) do
      gitlab_draft_reconciliation(
        merge_request,
        repository,
        change_request,
        draft,
        mutation_applied?
      )
    else
      _unknown -> {:error, :unknown_outcome}
    end
  end

  defp gitlab_draft_reconciliation(
         merge_request,
         repository,
         change_request,
         draft,
         mutation_applied?
       ) do
    if merge_request["draft"] == draft do
      disposition = if mutation_applied?, do: :updated, else: :reconciled

      normalize_change_request(
        merge_request,
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

  defp validate_merge_request_identity(merge_request, change_request) do
    if merge_request["source_branch"] == change_request.head_branch and
         merge_request["target_branch"] == change_request.base_branch do
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
    path = "/projects/#{segment(repository)}/merge_requests/#{change_request.number}"

    with {:ok, before_response} <- get(config, path),
         {:ok, before} <- expect(before_response, 200),
         :ok <- validate_merge_request_identity(before, change_request) do
      gitlab_close_decision(config, path, change_request, before)
    end
  end

  defp gitlab_close_decision(_config, _path, _change_request, %{"state" => state} = before)
       when state in ["closed", "merged"] do
    {:ok, %{action: :already_applied, external_id: to_string(before["id"])}}
  end

  defp gitlab_close_decision(config, path, change_request, _before) do
    request = %{method: :put, path: path, json: %{"state_event" => "close"}, retry: :never}
    mutation_applied? = match?({:ok, %{status: 200}}, Transport.request(config, :gitlab, request))
    reconcile_closed_merge_request(config, path, change_request, mutation_applied?)
  end

  defp reconcile_closed_merge_request(config, path, change_request, mutation_applied?) do
    with {:ok, response} <- get(config, path),
         {:ok, merge_request} <- expect(response, 200),
         :ok <- validate_merge_request_identity(merge_request, change_request) do
      closed_merge_request_reconciliation(
        merge_request,
        change_request,
        mutation_applied?
      )
    else
      _unknown -> {:error, :unknown_outcome}
    end
  end

  defp closed_merge_request_reconciliation(merge_request, change_request, mutation_applied?) do
    if merge_request["state"] in ["closed", "merged"] do
      action = if mutation_applied?, do: :closed, else: :already_applied

      {:ok,
       %{
         action: action,
         external_id: to_string(merge_request["id"] || change_request.external_id)
       }}
    else
      {:error, if(mutation_applied?, do: :provider_failure, else: :transport_failure)}
    end
  end

  defp comment(config, repository, change_request, operation_id, dedupe_key, opts) do
    body = Keyword.get(opts, :body)

    with true <- nonempty_string?(body),
         marker <- comment_marker(repository, change_request, operation_id, dedupe_key, body),
         {:ok, notes} <- list_notes(config, repository, change_request.number),
         {:ok, decision} <- AdapterSupport.marker_decision(notes, "body", marker) do
      gitlab_comment_decision(
        decision,
        config,
        repository,
        change_request,
        body,
        marker
      )
    else
      false -> {:error, :invalid_configuration}
      {:error, _reason} = error -> error
    end
  end

  defp comment_marker(repository, change_request, operation_id, dedupe_key, body) do
    AdapterSupport.operation_marker(
      :gitlab,
      repository,
      :comment,
      operation_id,
      dedupe_key,
      [change_request.external_id, AdapterSupport.body_digest(body)]
    )
  end

  defp gitlab_comment_decision({:found, found}, _config, _repo, _cr, _body, _marker) do
    {:ok, %{action: :already_applied, external_id: to_string(found["id"])}}
  end

  defp gitlab_comment_decision(:create, config, repository, cr, body, marker) do
    create_comment(config, repository, cr, body, marker)
  end

  defp create_comment(config, repository, change_request, body, marker) do
    path = "/projects/#{segment(repository)}/merge_requests/#{change_request.number}/notes"

    request = %{
      method: :post,
      path: path,
      json: %{"body" => AdapterSupport.append_marker(body, marker.exact)},
      retry: :never
    }

    case Transport.request(config, :gitlab, request) do
      {:ok, %{status: 201, body: note}} ->
        {:ok, %{action: :commented, external_id: to_string(note["id"])}}

      {:ok, %{status: status}} when status in [400, 409, 500, 502, 503, 504] ->
        reconcile_note(config, repository, change_request.number, marker)

      {:ok, response} ->
        expect(response, 201)

      {:error, _reason} ->
        reconcile_note(config, repository, change_request.number, marker)
    end
  end

  defp reconcile_note(config, repository, number, marker) do
    with {:ok, notes} <- list_notes(config, repository, number),
         {:ok, {:found, found}} <- AdapterSupport.marker_decision(notes, "body", marker) do
      {:ok, %{action: :already_applied, external_id: to_string(found["id"])}}
    else
      {:ok, :create} -> {:error, :unknown_outcome}
      {:error, _reason} = error -> error
    end
  end

  defp list_notes(config, repository, number) do
    list_note_page(config, repository, number, %{"per_page" => 100, "page" => 1}, [], 0)
  end

  defp list_note_page(_config, _repository, _number, _query, _acc, pages) when pages >= 20,
    do: {:error, :provider_failure}

  defp list_note_page(config, repository, number, query, acc, pages) do
    request = %{
      method: :get,
      path: "/projects/#{segment(repository)}/merge_requests/#{number}/notes",
      query: query,
      retry: :safe
    }

    with {:ok, response} <- Transport.request(config, :gitlab, request),
         {:ok, notes} <- expect(response, 200),
         true <- is_list(notes) do
      combined = acc ++ notes

      case gitlab_next_page(response.headers) do
        nil -> {:ok, combined}
        next -> list_note_page(config, repository, number, %{query | "page" => next}, combined, pages + 1)
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

  defp permissions(project, branch) do
    access_level =
      [
        get_in(project, ["permissions", "project_access", "access_level"]),
        get_in(project, ["permissions", "group_access", "access_level"])
      ]
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> nil end)

    %{
      repository_read: :allowed,
      branch_write: tri_state(branch["can_push"]),
      change_request_write: access_permission(access_level)
    }
  end

  defp require_write_permissions(%{
         branch_write: :allowed,
         change_request_write: :allowed
       }),
       do: :ok

  defp require_write_permissions(_permissions), do: {:error, :forbidden}

  defp access_permission(level) when is_integer(level) and level >= 30, do: :allowed
  defp access_permission(level) when is_integer(level), do: :denied
  defp access_permission(_unknown), do: :unknown

  defp tri_state(true), do: :allowed
  defp tri_state(false), do: :denied
  defp tri_state(_unknown), do: :unknown

  defp valid_repository?(repository) when is_binary(repository), do: nonempty_string?(repository)
  defp valid_repository?(_repository), do: false

  defp segment(value), do: URI.encode_www_form(value)
  defp nonempty_string?(value) when is_binary(value), do: String.trim(value) != ""

  defp valid_sha?(sha) when is_binary(sha), do: Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, sha)

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
