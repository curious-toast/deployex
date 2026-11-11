defmodule DeployexWeb.HotUpgradeLive do
  use DeployexWeb, :live_view

  require Logger

  alias Deployer.Github
  alias Deployer.HotUpgrade
  alias Deployer.HotUpgrade.Progress
  alias DeployexWeb.Guides
  alias DeployexWeb.Helper
  alias DeployexWeb.HostTime
  alias DeployexWeb.HotUpgrade.Data
  alias DeployexWeb.HotUpgrade.Steps
  alias DeployexWeb.UI.Icons
  alias DeployexWeb.UI.StepLeds
  alias DeployexWeb.UI.Tags
  alias Foundation.Common

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      current_user={@current_user}
      host_info={@host_info}
      recent_events={@recent_events}
      socket={@socket}
    >
      <div class="mx-auto flex max-w-[1180px] flex-col gap-4 px-7 pt-6 pb-12 max-md:px-4">
        <header class="flex flex-wrap items-center justify-between gap-x-6 gap-y-3">
          <div>
            <h1 class="text-[1.625rem] font-bold tracking-[-0.02em]">Hot Upgrade</h1>
            <p class="dx-muted mt-1 text-[0.8125rem]">
              Upgrade DeployEx itself without downtime
            </p>
          </div>
          <div
            :if={is_nil(@downloaded_release)}
            class="dx-seg2"
            role="group"
            aria-label="Release source"
          >
            <button
              id="hotupgrade-source-file"
              type="button"
              aria-pressed={to_string(@upload_method == :file)}
              phx-click="switch-upload-method"
              phx-value-method="file"
            >
              Upload File
            </button>
            <button
              id="hotupgrade-source-github"
              type="button"
              aria-pressed={to_string(@upload_method == :github)}
              phx-click="switch-upload-method"
              phx-value-method="github"
            >
              GitHub URL
            </button>
          </div>
        </header>

        <div id="hotupgrade-iac" class="dx-callout dx-callout-info m-0">
          <Icons.icon name="info" class="dx-callout-ico" />
          <div class="dx-callout-text">
            <b>This page upgrades DeployEx itself</b>
            <span>
              Your apps upgrade from their release bucket, not here. To keep the DeployEx version in code,
              set it in Terraform, and DeployEx upgrades itself to it.
            </span>
            <a
              class="dx-link"
              href={Guides.url("hot-upgrades", "method-4-terraform-iac-self-upgrade")}
              target="_blank"
              rel="noopener noreferrer"
            >
              Terraform self-upgrade guide<Icons.icon
                name="external"
                class="dx-ico ml-1 inline size-3.5"
              /><span class="sr-only"> (opens in a new tab)</span>
            </a>
          </div>
        </div>

        <section
          :if={show_progress?(@progress, @dismissed, @watched)}
          id="hotupgrade-progress"
          class="dx-card p-5"
          aria-labelledby="hotupgrade-progress-h"
        >
          <h2
            id="hotupgrade-progress-h"
            class="mb-4 flex flex-wrap items-baseline gap-x-3 gap-y-1 text-base font-semibold"
          >
            DeployEx hot upgrade
            <span class="dx-mono dx-muted text-[0.8125rem] font-normal">
              {@progress.from_version} → {@progress.to_version}
            </span>
            <time
              :if={@progress.state != :running and @progress.updated_at}
              id="hotupgrade-progress-at"
              class="dx-mono dx-muted text-xs font-normal"
              datetime={DateTime.to_iso8601(@progress.updated_at)}
              title={"Host time, #{HostTime.zone()}"}
            >
              {HostTime.format(@progress.updated_at, "%Y-%m-%d %H:%M")}
            </time>
          </h2>
          <StepLeds.row
            id="hotupgrade-progress-leds"
            label="Hot upgrade steps"
            steps={Steps.states(@progress)}
          />
          <p
            :if={@progress.state == :running}
            class="mt-3 flex items-center gap-2 text-[0.8125rem]"
            aria-live="polite"
          >
            <span class="loading loading-spinner loading-sm"></span>{Steps.line(@progress)}
          </p>
          <div
            :if={@progress.state == :success}
            class="dx-callout dx-callout-info m-0 mt-4"
            role="status"
          >
            <Icons.icon name="check-circle" class="dx-callout-ico" />
            <span class="dx-callout-text">{List.last(@progress.messages)}</span>
          </div>
          <.failure :if={@progress.state == :error} id="hotupgrade-progress-error">
            <b>{Steps.line(@progress)}</b>
            <span>{List.last(@progress.messages)}</span>
          </.failure>
          <div :if={@progress.state != :running} class="mt-4 flex justify-end">
            <button
              id="hotupgrade-progress-done"
              type="button"
              class="dx-btn"
              phx-click="hotupgrade-progress-done"
            >
              Done
            </button>
          </div>
        </section>

        <section
          :if={@upload_method == :file and is_nil(@downloaded_release)}
          class="dx-card p-5"
          aria-labelledby="hotupgrade-upload"
        >
          <h2 id="hotupgrade-upload" class="mb-4 flex items-center gap-2 text-base font-semibold">
            <Icons.icon name="arrow-up-tray" class="dx-ico dx-muted size-5" />
            Upload Hot Upgrade Release
          </h2>

          <form id="upload-form" phx-submit="validate-upload" phx-change="validate-upload">
            <div class="dx-upload" phx-drop-target={@uploads.hotupgrade.ref}>
              <.live_file_input upload={@uploads.hotupgrade} class="hidden" />
              <Icons.icon name="document" stroke="1.4" class="dx-ico dx-muted mx-auto mb-3 size-12" />
              <label for={@uploads.hotupgrade.ref} class="cursor-pointer text-base font-medium">
                Drop your .tar.gz file here or <span class="dx-upload-browse">browse</span>
              </label>
              <p class="dx-muted mt-2 text-[0.8125rem]">
                Maximum file size: {trunc(@uploads.hotupgrade.max_file_size / 1_000_000)}MB
              </p>
            </div>

            <div :for={entry <- @uploads.hotupgrade.entries} class="dx-upload-entry">
              <div class="mb-2 flex items-center justify-between gap-3">
                <div class="flex min-w-0 items-center gap-3">
                  <Icons.icon name="document" class="dx-ico dx-muted size-5" />
                  <div class="min-w-0">
                    <p class="truncate font-medium">{entry.client_name}</p>
                    <p class="dx-muted text-[0.8125rem]">{Helper.format_bytes(entry.client_size)}</p>
                  </div>
                </div>
                <button
                  type="button"
                  class="dx-ghost"
                  aria-label={"Cancel the upload of #{entry.client_name}"}
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                >
                  <Icons.icon name="x-mark" class="dx-ico size-4" />
                </button>
              </div>
              <.bar label="Upload progress" percent={entry.progress} />
              <p class="dx-muted mt-1 text-xs">{entry.progress}% uploaded</p>
              <.failure :for={err <- upload_errors(@uploads.hotupgrade, entry)}>
                {Helper.error_to_string(err)}
              </.failure>
            </div>

            <.failure :for={err <- upload_errors(@uploads.hotupgrade)}>
              {Helper.error_to_string(err)}
            </.failure>
          </form>
        </section>

        <section
          :if={@upload_method == :github and is_nil(@downloaded_release)}
          class="dx-card p-5"
          aria-labelledby="hotupgrade-github"
        >
          <h2 id="hotupgrade-github" class="mb-4 flex items-center gap-2 text-base font-semibold">
            <Icons.icon name="arrow-down-tray" class="dx-ico dx-muted size-5" /> Download from GitHub
          </h2>

          <%!-- A text field followed by a password field looks like a sign in form to a
                password manager, which then fills the DeployEx credentials into the URL and
                token below. The autocomplete hints here and on the inputs keep it away. --%>
          <.form
            for={@form}
            id="github-download-form"
            phx-change="github-download-form-update"
            phx-submit="download-from-github"
            class="flex flex-col gap-4"
            autocomplete="off"
          >
            <div class="dx-field">
              <label for="hotupgrade-github-url">GitHub Artifact URL</label>
              <input
                id="hotupgrade-github-url"
                type="text"
                name="github_url"
                value={@form.params["github_url"]}
                placeholder="https://github.com/user/repo/actions/runs/123/artifacts/456"
                class="dx-input"
                aria-describedby="hotupgrade-github-url-help"
                autocomplete="off"
                data-1p-ignore
                data-lpignore="true"
                required
              />
              <span id="hotupgrade-github-url-help" class="dx-muted text-xs">
                Paste the GitHub Actions artifact URL
              </span>
            </div>

            <div class="dx-field">
              <label for="hotupgrade-github-token">GitHub Token (optional)</label>
              <%!-- new-password rather than off: Chrome ignores off for password fields
                    but will not fill a stored credential into a new-password one --%>
              <input
                id="hotupgrade-github-token"
                type="password"
                name="github_token"
                value={@form.params["github_token"]}
                placeholder="ghp_xxxxxxxxxxxx"
                class="dx-input dx-mono"
                aria-describedby="hotupgrade-github-token-help"
                autocomplete="new-password"
                data-1p-ignore
                data-lpignore="true"
              />
              <span id="hotupgrade-github-token-help" class="dx-muted text-xs">
                Required for private repositories or artifacts
              </span>
            </div>

            <div
              :if={@github.download_status == :downloading}
              class="dx-callout dx-callout-info m-0 flex-col items-stretch"
            >
              <span>Downloading from GitHub...</span>
              <div class="flex items-center gap-3">
                <.bar label="Download progress" percent={@github.download_progress} />
                <span class="dx-mono w-12 text-right text-[0.8125rem] font-semibold">
                  {@github.download_progress}%
                </span>
                <button type="button" phx-click="cancel-github-download" class="dx-btn">
                  Cancel
                </button>
              </div>
            </div>

            <.failure :if={@github.download_error} id="github-download-error">
              {@github.download_error}
            </.failure>

            <div class="flex justify-end">
              <button
                :if={@form.params["github_url"] != ""}
                type="submit"
                class="dx-btn dx-btn-primary"
                disabled={@github.download_status == :downloading}
              >
                <Icons.icon name="arrow-down-tray" class="dx-ico size-4" /> Download Release
              </button>
            </div>
          </.form>

          <div class="dx-callout dx-callout-info m-0 mt-4">
            <Icons.icon name="info" class="dx-callout-ico" />
            <div class="dx-callout-text">
              <b>How to get the artifact URL</b>
              <ol class="list-inside list-decimal text-[0.8125rem] text-(--dx-base-content)">
                <li>Go to your GitHub repository's Actions tab</li>
                <li>Click on the workflow run</li>
                <li>Find the artifact in the "Artifacts" section</li>
                <li>Right-click on the artifact name and copy the link</li>
              </ol>
            </div>
          </div>
        </section>

        <section
          :if={@downloaded_release}
          class="dx-card overflow-hidden p-5"
          aria-labelledby="hotupgrade-release"
          phx-mounted={
            JS.transition(
              {"ease-in duration-300", "opacity-0 scale-95", "opacity-100 scale-100"},
              time: 300
            )
          }
        >
          <h2
            id="hotupgrade-release"
            class="flex flex-wrap items-center gap-x-3 gap-y-1 text-base font-semibold"
          >
            <Icons.icon
              name={if @downloaded_release.error, do: "x-circle", else: "check-circle"}
              class="dx-ico size-5"
              style={"color: var(#{if @downloaded_release.error, do: "--dx-error-text", else: "--dx-success-text"})"}
            /> Uploaded release
            <span :if={!@downloaded_release.error} class="dx-mono">
              {@downloaded_release.name} {@downloaded_release.to_version}
            </span>
          </h2>

          <dl class="mt-4 flex flex-wrap gap-x-8 gap-y-3">
            <.detail :if={!@downloaded_release.error} label="Version" mono>
              {@downloaded_release.to_version}
            </.detail>
            <.detail label="Current version" mono>
              {@downloaded_release.from_version || "N/A"}
            </.detail>
            <.detail :if={!@downloaded_release.error} label="Upgrade type">
              <Tags.deploy_tag type={:hot} />
            </.detail>
            <.detail :if={@downloaded_release.error} label="Error">
              <span style="color: var(--dx-error-text)">{@downloaded_release.error}</span>
            </.detail>
          </dl>
          <dl class="mt-3 flex flex-wrap gap-x-8 gap-y-3">
            <.detail label="Filename" mono>{@downloaded_release.filename}</.detail>
            <.detail label="Size">{Helper.format_bytes(@downloaded_release.size)}</.detail>
            <.detail label="Sha256" mono>{@downloaded_release.sha256}</.detail>
          </dl>

          <%!-- Open by default, and phx-update="ignore" keeps the viewer's toggle through the renders --%>
          <details
            :if={@downloaded_release.jellyfish_info not in [nil, []]}
            id="hotupgrade-release-apps"
            class="mt-3 text-[0.8125rem]"
            open
            phx-update="ignore"
          >
            <summary class="cursor-pointer font-semibold">
              Applications in this release ({length(@downloaded_release.jellyfish_info)})
            </summary>
            <table class="mt-2 w-full text-left text-xs">
              <thead>
                <tr class="dx-lbl">
                  <th class="pb-1 font-semibold">Name</th>
                  <th class="pb-1 font-semibold">Type</th>
                  <th class="pb-1 font-semibold">From</th>
                  <th class="pb-1 font-semibold">To</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={app <- @downloaded_release.jellyfish_info}>
                  <td class="dx-mono py-1 font-medium">{app.name}</td>
                  <td class="py-1">{app.type}</td>
                  <td class="dx-mono dx-muted py-1">{app.from}</td>
                  <td class="dx-mono py-1 font-medium">{app.to}</td>
                </tr>
              </tbody>
            </table>
          </details>

          <div
            :if={!asking_apply?(@live_action, @downloaded_release, @progress)}
            class="mt-4 flex justify-end gap-2"
          >
            <button type="button" phx-click="remove-release" class="dx-btn">Remove</button>
            <.link
              :if={!@downloaded_release.error and !running?(@progress)}
              id={Helper.normalize_id("hotupgrade-apply-#{@downloaded_release.name}")}
              class="dx-btn dx-btn-primary"
              patch={~p"/hotupgrade/apply"}
            >
              <Icons.icon name="check" class="dx-ico size-4" /> Apply Hot Upgrade
            </.link>
          </div>
          <div
            :if={asking_apply?(@live_action, @downloaded_release, @progress)}
            id="hotupgrade-ask"
            class="dx-ask dx-ask-warn -mx-5 mt-5 -mb-5"
            role="group"
            aria-label="Confirm the hot upgrade"
          >
            <span class="flex-[1_1_360px] text-base">
              <b>Apply the hot upgrade to {@downloaded_release.to_version}?</b>
              DeployEx keeps running and its code is replaced in place, and the monitored applications are
              not affected. The upgrade cannot be undone from this page.
              A failure does not roll back on its own, and a restart of the service returns DeployEx to the
              last permanent version.
            </span>
            <button
              id="hotupgrade-execute"
              type="button"
              class="dx-btn dx-btn-danger"
              phx-click="hotupgrade-execute"
            >
              Apply hot upgrade
            </button>
            <.link id="hotupgrade-cancel" class="dx-btn no-underline" patch={~p"/hotupgrade"}>
              Cancel
            </.link>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :percent, :integer, required: true

  defp bar(assigns) do
    ~H"""
    <span
      class="dx-lbar"
      role="progressbar"
      aria-label={@label}
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={@percent}
    >
      <i style={"width: #{@percent}%; background: var(--dx-nav-active)"}></i>
    </span>
    """
  end

  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp failure(assigns) do
    ~H"""
    <div id={@id} class="dx-callout dx-callout-error m-0 mt-3" role="alert">
      <Icons.icon name="x-circle" class="dx-callout-ico" />
      <span class="dx-callout-text">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :mono, :boolean, default: false
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="dx-lbl">{@label}</dt>
      <dd class={["text-[0.8125rem] break-all", @mono && "dx-mono"]}>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) when is_connected?(socket) do
    # Subscribe to receive hot upgrade events
    HotUpgrade.subscribe_events()

    # Subscribe to receive github download events
    Github.subscribe_download_events()

    {:ok, default_assigns(socket)}
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, default_assigns(socket)}
  end

  defp default_assigns(socket) do
    socket
    |> assign(:downloaded_release, nil)
    |> assign_progress(HotUpgrade.deployex_progress())
    |> assign(:dismissed, nil)
    |> assign(:current_path, "/hotupgrade")
    |> assign(:node, Node.self())
    |> assign(:upload_method, :file)
    |> assign(:github, github_new())
    |> assign(form: to_form(default_form_options()))
    |> allow_upload(:hotupgrade,
      accept: [".gz"],
      max_entries: 1,
      auto_upload: true,
      max_file_size: 300_000_000,
      progress: &handle_progress/3
    )
  end

  defp default_form_options, do: %{"github_url" => "", "github_token" => ""}

  # The download panel renders download_error, so the reason stays where the operator was
  # looking. A flash alone is missed easily, and github_new/2 would clear the field that
  # exists to show it
  defp github_download_failed(socket, msg) do
    socket
    |> assign(:github, %{github_new() | download_error: msg})
    |> put_flash(:error, msg)
  end

  # A viewer who saw the run running also sees its success. Anyone sees a run that runs or failed
  # A loaded release that this host just upgraded to is cleared, so the upload box shows again
  defp assign_progress(socket, progress) do
    socket
    |> assign(:progress, progress)
    |> assign(:watched, Map.get(socket.assigns, :watched, false) or running?(progress))
    |> update(:downloaded_release, &if(applied?(progress, &1), do: nil, else: &1))
  end

  defp show_progress?(nil, _dismissed, _watched), do: false
  defp show_progress?(progress, progress, _watched), do: false
  defp show_progress?(%Progress{state: :success}, _dismissed, watched), do: watched
  defp show_progress?(%Progress{}, _dismissed, _watched), do: true

  defp running?(progress), do: match?(%Progress{state: :running}, progress)

  defp asking_apply?(action, release, progress),
    do: action == :apply and is_nil(release.error) and not running?(progress)

  # A release that this host just upgraded to has nothing left to apply
  # The check gives the release versions as charlists
  defp applied?(%Progress{state: :success, to_version: version}, %{to_version: to_version}),
    do: version == to_string(to_version)

  defp applied?(_progress, _release), do: false

  defp github_new(id \\ nil, status \\ nil) do
    %{
      download_id: id,
      download_status: status,
      download_progress: 0,
      download_error: nil
    }
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Hot upgrade")
  end

  defp apply_action(%{assigns: %{downloaded_release: nil}} = socket, :apply, _params) do
    socket
    |> assign(:page_title, "Hot upgrade")
    |> push_navigate(to: ~p"/hotupgrade")
  end

  defp apply_action(socket, :apply, _params) do
    assign(socket, :page_title, "Hot upgrade confirmation")
  end

  @impl true
  def handle_event("validate-upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(
        "github-download-form-update",
        %{"github_token" => github_token, "github_url" => github_url},
        socket
      ) do
    {:noreply,
     socket
     |> assign(form: to_form(%{"github_token" => github_token, "github_url" => github_url}))}
  end

  def handle_event("switch-upload-method", %{"method" => method}, socket) do
    upload_method = if method == "github", do: :github, else: :file

    {:noreply,
     socket
     |> assign(:upload_method, upload_method)
     |> assign(:github, github_new())}
  end

  def handle_event("download-from-github", _params, %{assigns: %{form: form}} = socket) do
    url = form.params["github_url"]
    github_token = form.params["github_token"]

    {:ok, id} = Github.download_artifact(url, github_token)

    {:noreply, assign(socket, :github, github_new(id, :downloading))}
  end

  def handle_event(
        "cancel-github-download",
        _params,
        %{assigns: %{github: %{download_status: :downloading, download_id: id}}} = socket
      )
      when id != nil do
    Github.stop_download_artifact(id)
    {:noreply, assign(socket, :github, github_new())}
  end

  def handle_event("cancel-github-download", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :hotupgrade, ref)}
  end

  def handle_event("remove-release", _params, socket) do
    {:noreply,
     socket
     |> assign(:downloaded_release, nil)
     |> push_patch(to: ~p"/hotupgrade")}
  end

  # Done hides the run it was clicked on for this viewer. A new run differs, so it shows again
  def handle_event("hotupgrade-progress-done", _params, socket) do
    {:noreply,
     socket
     |> assign(:dismissed, socket.assigns.progress)
     |> push_patch(to: ~p"/hotupgrade")}
  end

  # The check runs here, before the upgrade starts in the background, so a refused release is
  # reported at once. A started one shows its first step until the first event replaces it
  def handle_event(
        "hotupgrade-execute",
        _params,
        %{assigns: %{downloaded_release: release}} = socket
      ) do
    case HotUpgrade.deployex_execute(release.download_path, sync_execution: false) do
      :ok ->
        progress = %Progress{
          sname: release.name,
          from_version: to_string(release.from_version),
          to_version: to_string(release.to_version)
        }

        {:noreply, socket |> assign_progress(progress) |> push_patch(to: ~p"/hotupgrade")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Hot upgrade refused: #{refusal(reason)}")
         |> push_patch(to: ~p"/hotupgrade")}
    end
  end

  # Every viewer follows the run, whatever started it. The table holds the run, so an event from this
  # host is a reason to read it again
  @impl true
  def handle_info(
        {:hot_upgrade_progress, source_node, _sname, _message},
        %{assigns: %{node: node}} = socket
      )
      when source_node == node,
      do: {:noreply, assign_progress(socket, HotUpgrade.deployex_progress())}

  def handle_info(
        {:hot_upgrade_complete, source_node, _sname, _status, _message},
        %{assigns: %{node: node}} = socket
      )
      when source_node == node,
      do: {:noreply, assign_progress(socket, HotUpgrade.deployex_progress())}

  def handle_info(
        {:github_download_artifact, source_node,
         %{artifact_path: artifact_path, artifact_name: artifact_name, id: id}, :ok},
        %{
          assigns: %{
            node: node,
            github: %{download_status: :downloading, download_id: download_id}
          }
        } = socket
      )
      when source_node == node and id == download_id do
    with {:ok, %File.Stat{size: size}} <- File.stat(artifact_path),
         {:ok, downloaded_release} <- handle_release(artifact_path, artifact_name, size) do
      {:noreply,
       socket
       |> assign(:github, github_new())
       |> assign(:downloaded_release, downloaded_release)}
    else
      {:postpone, %Data{error: error}} ->
        msg = "Error while handling file: #{artifact_name}, reason: #{error}"
        Logger.error(msg)

        {:noreply, github_download_failed(socket, msg)}

      error ->
        msg = "Error while handling file: #{artifact_name}"
        Logger.error(msg <> ", reason: #{inspect(error)}")

        {:noreply, github_download_failed(socket, msg)}
    end
  end

  def handle_info(
        {:github_download_artifact, source_node, _data, {:downloading, progress}},
        %{assigns: %{node: node, github: %{download_status: :downloading} = github}} = socket
      )
      when source_node == node do
    {:noreply,
     socket
     |> assign(:github, %{github | download_progress: progress})}
  end

  def handle_info(_event, socket) do
    {:noreply, socket}
  end

  defp handle_progress(:hotupgrade, entry, socket) when entry.done? do
    downloaded_release =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        handle_release(path, entry.client_name, entry.client_size)
      end)

    {:noreply, assign(socket, :downloaded_release, downloaded_release)}
  end

  defp handle_progress(:hotupgrade, _entry, socket) do
    {:noreply, socket}
  end

  # Helper Functions

  defp handle_release(path, filename, size) do
    uploads_path = "#{:code.priv_dir(:deployex_web)}/static/uploads"
    File.mkdir_p!(uploads_path)
    download_path = uploads_path <> "/#{filename}"
    File.cp!(path, download_path)

    hotupgrade = %Data{
      filename: filename,
      size: size,
      download_path: download_path
    }

    # Execute checks
    with true <- String.ends_with?(filename, ".tar.gz"),
         {:ok, check_data} <- HotUpgrade.deployex_check(download_path),
         sha256 <- Common.sha256(download_path) do
      {:ok, struct(%{hotupgrade | sha256: sha256}, Map.from_struct(check_data))}
    else
      false ->
        {:postpone, %{hotupgrade | error: " not a .tar.gz file"}}

      {:error, reason} ->
        {:postpone, %{hotupgrade | error: refusal(reason)}}
    end
  end

  # Why the check refused a release, at upload and again at Apply
  defp refusal(:full_deployment), do: "full deployment only"

  defp refusal({:otp_mismatch, %{running_otp: otp}}),
    do: "wrong OTP, this installation runs OTP #{otp}"

  defp refusal(:invalid_release_file), do: "not a deployex release"
  defp refusal(_reason), do: "invalid release"
end
