defmodule Aelita2.WebhookController do
  use Aelita2.Web, :controller

  alias Aelita2.Installation
  alias Aelita2.Patch
  alias Aelita2.Project
  alias Aelita2.User
  alias Aelita2.Batcher

  @doc """
  This action is reached via `/webhook/:provider`
  """
 def webhook(conn, %{"provider" => "github"}) do
    event = hd(get_req_header(conn, "x-github-event"))
    do_webhook conn, "github", event
    conn
    |> send_resp(200, "")
  end

  def do_webhook(_conn, "github", "ping") do
    :ok
  end

  def do_webhook(conn, "github", "integration_installation") do
    payload = conn.body_params
    installation_xref = payload["installation"]["id"]
    case payload["action"] do
      "deleted" -> Repo.delete_all(from(
        i in Installation,
        where: i.installation_xref == ^installation_xref
      ))
      "created" -> create_installation_by_xref installation_xref
      _ -> nil
    end
    :ok
  end

  def do_webhook(conn, "github", "integration_installation_repositories") do
    payload = conn.body_params
    installation_xref = payload["installation"]["id"]
    installation = Repo.get_by!(Installation, installation_xref: installation_xref)
    :ok = case payload["action"] do
      "removed" -> :ok
      "added" -> :ok
    end
    payload["repositories_removed"]
    |> Enum.map(&from(p in Project, where: p.repo_xref == ^&1["id"]))
    |> Enum.each(&Repo.delete_all/1)
    payload["repositories_added"]
    |> Enum.map(&%Project{repo_xref: &1["id"], name: &1["full_name"], installation: installation})
    |> Enum.each(&Repo.insert!/1)
    :ok
  end

  def do_webhook(conn, "github", "pull_request") do
    project = Repo.get_by!(Project, repo_xref: conn.body_params["repository"]["id"])
    author = sync_user(conn.body_params["pull_request"]["user"])
    patch = Repo.get_by(Patch, project_id: project.id, pr_xref: conn.body_params["pull_request"]["number"])
    do_webhook_pr(conn, conn.body_params["action"], project, patch, author)
  end

  def do_webhook(conn, "github", "issue_comment") do
    if Map.has_key?(conn.body_params["issue"], "pull_request") do
      project = Repo.get_by!(Project, repo_xref: conn.body_params["repository"]["id"])
      patch = Repo.get_by!(Patch, project_id: project.id, pr_xref: conn.body_params["issue"]["number"])
      author = sync_user(conn.body_params["issue"]["user"])
      commenter = sync_user(conn.body_params["comment"]["user"])
      comment = conn.body_params["comment"]["body"]
      do_webhook_comment(conn, "github", project, patch, author, commenter, comment)
    end
  end

  def do_webhook(conn, "github", "pull_request_review_comment") do
    project = Repo.get_by!(Project, repo_xref: conn.body_params["repository"]["id"])
    patch = Repo.get_by!(Patch, project_id: project.id, pr_xref: conn.body_params["issue"]["number"])
    author = sync_user(conn.body_params["issue"]["user"])
    commenter = sync_user(conn.body_params["comment"]["user"])
    comment = conn.body_params["comment"]["body"]
    do_webhook_comment(conn, "github", project, patch, author, commenter, comment)
  end

  def do_webhook(conn, "github", "pull_request_review") do
    project = Repo.get_by!(Project, repo_xref: conn.body_params["repository"]["id"])
    patch = Repo.get_by!(Patch, project_id: project.id, pr_xref: conn.body_params["issue"]["number"])
    author = sync_user(conn.body_params["issue"]["user"])
    commenter = sync_user(conn.body_params["comment"]["user"])
    comment = conn.body_params["comment"]["body"]
    do_webhook_comment(conn, "github", project, patch, author, commenter, comment)
  end

  def do_webhook(conn, "github", "status") do
    identifier = conn.body_params["context"]
    commit = conn.body_params["sha"]
    state = Aelita2.Integration.GitHub.map_state_to_status(conn.body_params["state"])
    Aelita2.Batcher.status(commit, identifier, state)
  end

  def do_webhook_pr(conn, "opened", project, patch, author) do
    nil = patch
    Repo.insert!(%Patch{
      project: project,
      batch: nil,
      pr_xref: conn.body_params["pull_request"]["number"],
      title: conn.body_params["pull_request"]["title"],
      body: conn.body_params["pull_request"]["body"],
      commit: conn.body_params["pull_request"]["head"]["sha"],
      author: author
    })
  end

  def do_webhook_pr(_conn, "closed", _project, patch, _author) do
    Repo.delete!(patch)
  end

  def do_webhook_pr(conn, "synchronize", _project, patch, _author) do
    commit = conn.body_params["pull_request"]["head"]["sha"]
    Repo.update!(Patch.changeset(patch, %{commit: commit}))
  end

  def do_webhook_pr(_conn, "assigned", _project, _patch, _author) do
    :ok
  end

  def do_webhook_pr(_conn, "unassigned", _project, _patch, _author) do
    :ok
  end

  def do_webhook_pr(_conn, "labeled", _project, _patch, _author) do
    :ok
  end

  def do_webhook_pr(_conn, "unlabeled", _project, _patch, _author) do
    :ok
  end

  def do_webhook_pr(conn, "edited", _project, patch, _author) do
    title = conn.title_params["pull_request"]["title"]
    body = conn.body_params["pull_request"]["body"]
    Repo.update!(Patch.changeset(patch, %{title: title, body: body}))
  end

  def do_webhook_comment(_conn, "github", _project, patch, _author, _commenter, comment) do
    activation_phrase = Application.get_env(:aelita2, Aelita2)[:activation_phrase]
    if :binary.match(comment, activation_phrase) != :nomatch do
      Batcher.reviewed(patch)
    end
  end

  def create_installation_by_xref(installation_xref) do
    i = Repo.insert!(%Installation{
      installation_xref: installation_xref
    })
    Aelita2.Integration.GitHub.get_installation_token!(installation_xref)
    |> Aelita2.Integration.GitHub.get_my_repos!()
    |> Enum.map(&%Project{repo_xref: &1.id, name: &1.name, installation: i})
    |> Enum.each(&Repo.insert!/1)
  end

  def sync_user(user_json) do
    user = case Repo.get_by(User, user_xref: user_json["id"]) do
      nil -> %User{
        id: nil,
        user_xref: user_json["id"],
        login: user_json["login"]}
      user -> user
    end
    if is_nil(user.id) do
      Repo.insert!(user)
    else
      if user.login != user_json["login"] do
        Repo.update! User.changeset(user, %{login: user_json["login"]})
      else
        user
      end
    end
  end
end