defmodule DeployexWeb.HotUpgradeLive do
  use DeployexWeb, :live_view

  require Logger

  alias Deployer.Github
  alias Deployer.HotUpgrade
  alias DeployexWeb.Components.Confirm
  alias DeployexWeb.Components.Progress
  alias DeployexWeb.Guides
  alias DeployexWeb.Helper
  alias DeployexWeb.HotUpgrade.Data
  alias DeployexWeb.UI.Icons
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
          <div class="dx-seg2" role="group" aria-label="Release source">
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

        <section :if={@upload_method == :file} class="dx-card p-5" aria-labelledby="hotupgrade-upload">
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
          :if={@upload_method == :github}
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
          class="dx-card p-5"
          aria-labelledby="hotupgrade-release"
          phx-mounted={
            JS.transition(
              {"ease-in duration-300", "opacity-0 scale-95", "opacity-100 scale-100"},
              time: 300
            )
          }
        >
          <h2 id="hotupgrade-release" class="mb-4 flex items-center gap-2 text-base font-semibold">
            <Icons.icon
              name={if @downloaded_release.error, do: "x-circle", else: "check-circle"}
              class="dx-ico size-5"
              style={"color: var(#{if @downloaded_release.error, do: "--dx-error-text", else: "--dx-success-text"})"}
            /> Uploaded release
          </h2>

          <div class="mb-5 grid grid-cols-1 gap-4 md:grid-cols-3">
            <div class="dx-upload-box">
              <h3 class="mb-3 text-[0.875rem] font-semibold">Release Information</h3>
              <dl class="flex flex-col gap-2">
                <.detail label="Application" mono>{@downloaded_release.name}</.detail>
                <.detail :if={!@downloaded_release.error} label="Version" mono>
                  {@downloaded_release.to_version}
                </.detail>
                <.detail label="Filename" mono>{@downloaded_release.filename}</.detail>
                <.detail label="Size">{Helper.format_bytes(@downloaded_release.size)}</.detail>
                <.detail label="Sha256" mono>{@downloaded_release.sha256}</.detail>
              </dl>
            </div>

            <div class="dx-upload-box">
              <h3 class="mb-3 text-[0.875rem] font-semibold">Upgrade Details</h3>
              <dl class="flex flex-col gap-2">
                <.detail label="Current Version" mono>
                  {@downloaded_release.from_version || "N/A"}
                </.detail>
                <.detail :if={!@downloaded_release.error} label="Target Version" mono>
                  {@downloaded_release.to_version}
                </.detail>
                <.detail :if={!@downloaded_release.error} label="Upgrade Type">
                  <Tags.deploy_tag type={:hot} />
                </.detail>
                <.detail :if={@downloaded_release.error} label="Error">
                  <span style="color: var(--dx-error-text)">{@downloaded_release.error}</span>
                </.detail>
              </dl>
            </div>

            <div class="dx-upload-box">
              <h3 class="mb-3 text-[0.875rem] font-semibold">Applications info</h3>
              <table
                :if={@downloaded_release.jellyfish_info not in [nil, []]}
                class="w-full text-left text-xs"
              >
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
              <p
                :if={@downloaded_release.jellyfish_info in [nil, []]}
                class="dx-muted py-4 text-center text-[0.8125rem]"
              >
                No application info available
              </p>
            </div>
          </div>

          <div :if={!@downloaded_release.error} class="dx-callout dx-callout-warning m-0 mb-5">
            <Icons.icon name="warning" class="dx-callout-ico" />
            <div class="dx-callout-text">
              <b>Important Notice</b>
              <ul class="list-inside list-disc text-[0.8125rem] text-(--dx-base-content)">
                <li>This will perform a hot upgrade without restarting the application</li>
                <li>Ensure the release is compatible with the current version</li>
                <li>This operation cannot be easily undone</li>
                <li>Consider backing up current state before proceeding</li>
              </ul>
            </div>
          </div>

          <div class="flex justify-end gap-2">
            <button type="button" phx-click="remove-release" class="dx-btn">Remove</button>
            <.link
              :if={!@downloaded_release.error}
              id={Helper.normalize_id("hotupgrade-apply-#{@downloaded_release.name}")}
              class="dx-btn dx-btn-primary"
              patch={~p"/hotupgrade/apply"}
            >
              <Icons.icon name="check" class="dx-ico size-4" /> Apply Hot Upgrade
            </.link>
          </div>
        </section>
      </div>
    </Layouts.app>

    <%= cond do %>
      <% @live_action == :apply and @upgrade_state != :init -> %>
        <Progress.content id={"hotupgrade-progress-modal-#{@downloaded_release.name}"}>
          <:header>Hot Upgrade Progress</:header>

          <div id="upgrade-progress" class="mt-6 flex flex-col gap-4">
            <div class="flex items-center justify-between px-4">
              <h3 class="font-semibold">Upgrade Progress</h3>
              <span :if={@upgrade_state == :running} class="dx-muted text-[0.8125rem]">
                Step {length(@upgrade_progress)} of {@total_upgrade_steps}
              </span>
            </div>
            <div class="dx-upload-box">
              <div
                id="upgrade-progress-log"
                phx-hook="AutoScroll"
                class="dx-mono flex max-h-48 flex-col gap-2 overflow-y-auto text-[0.8125rem]"
              >
                <div :for={line <- @upgrade_progress} class="flex items-start gap-2">
                  <Icons.icon
                    name="check"
                    class="dx-ico mt-0.5 size-4 flex-none"
                    style="color: var(--dx-success-text)"
                  />
                  <span class="flex-1">{line}</span>
                </div>
                <div
                  :if={@upgrade_state == :running and @upgrade_progress != []}
                  class="dx-muted flex items-center gap-2 italic"
                >
                  <span class="loading loading-spinner loading-xs"></span> Processing...
                </div>
              </div>
            </div>
            <div :if={@upgrade_state not in [:success, :error]} class="flex items-center gap-2 px-4">
              <span class="loading loading-spinner loading-sm"></span>
              <span class="dx-muted text-[0.8125rem]">Applying hot upgrade…</span>
            </div>
            <div :if={@upgrade_state == :success} class="dx-callout dx-callout-info m-0" role="status">
              <Icons.icon name="check-circle" class="dx-callout-ico" />
              <span class="dx-callout-text">Hot upgrade completed successfully!</span>
            </div>
            <.failure :if={@upgrade_state == :error}>Hot upgrade failed!</.failure>
          </div>

          <:footer :if={@upgrade_state != :running}>
            <Progress.done_button
              id="hotupgrade-progress-done"
              event="hotupgrade-progress-done"
              value={@downloaded_release.name}
            >
              Done
            </Progress.done_button>
          </:footer>
        </Progress.content>
      <% @live_action == :apply and @downloaded_release != nil and @downloaded_release.error == nil -> %>
        <Confirm.content id={"hotupgrade-modal-#{@downloaded_release.name}"}>
          <:header>Hot upgrade</:header>

          <div class="flex flex-col gap-4">
            <p>
              You are about to perform a <b style="color: var(--dx-hot-text)">hot upgrade</b>
              for <span class="dx-mono font-semibold">{@downloaded_release.name}</span>.
            </p>
            <div class="dx-callout dx-callout-warning m-0">
              <Icons.icon name="warning" class="dx-callout-ico" />
              <div class="dx-callout-text">
                <b>Before you apply</b>
                <ul class="list-inside list-disc text-[0.8125rem] text-(--dx-base-content)">
                  <li>DeployEx keeps running, its code is replaced in place</li>
                  <li>Processes with a code_change callback have their state migrated live</li>
                  <li>Monitored applications are not affected, they run on separate nodes</li>
                  <li>
                    A failure does not roll back on its own. DeployEx stays up and logs the
                    error, and restarting the service returns it to the last permanent version
                  </li>
                </ul>
              </div>
            </div>
          </div>

          <:footer>
            <Confirm.cancel_button id="hotupgrade-cancel">
              Cancel
            </Confirm.cancel_button>
            <Confirm.danger_button
              id="hotupgrade-execute"
              event="hotupgrade-execute"
              value={@downloaded_release.name}
            >
              Yes, Apply Hot Upgrade
            </Confirm.danger_button>
          </:footer>
        </Confirm.content>
      <% true -> %>
    <% end %>
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
    |> assign(:applying_upgrade, false)
    |> assign(:upgrade_progress, [])
    |> assign(:upgrade_state, :init)
    |> assign(:total_upgrade_steps, 8)
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
    socket
    |> assign(:applying_upgrade, true)
    |> assign(:page_title, "Hot upgrade confirmation")
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

  def handle_event("confirm-close-modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:applying_upgrade, false)
     |> assign(:upgrade_state, :init)
     |> push_patch(to: ~p"/hotupgrade")}
  end

  def handle_event(event, _params, socket)
      when event in ["remove-release", "hotupgrade-progress-done"] do
    {:noreply,
     socket
     |> assign(:downloaded_release, nil)
     |> assign(:applying_upgrade, false)
     |> assign(:upgrade_state, :init)
     |> assign(:upgrade_progress, [])
     |> push_patch(to: ~p"/hotupgrade")}
  end

  def handle_event("hotupgrade-execute", _params, socket) do
    # Start Hotupgrade execution
    HotUpgrade.deployex_execute(socket.assigns.downloaded_release.download_path,
      sync_execution: false
    )

    {:noreply,
     socket
     |> assign(:applying_upgrade, true)
     |> assign(:upgrade_state, :running)
     |> assign(:upgrade_progress, [])
     |> assign(:page_title, "Hot upgrade in progress")}
  end

  @impl true
  def handle_info(
        {:hot_upgrade_progress, source_node, _sname, msg},
        %{assigns: %{node: node, applying_upgrade: true}} = socket
      )
      when source_node == node do
    {:noreply,
     socket
     |> update(:upgrade_progress, fn logs -> logs ++ [msg] end)}
  end

  def handle_info(
        {:hot_upgrade_complete, source_node, _sname, :ok, msg},
        %{assigns: %{node: node, applying_upgrade: true}} = socket
      )
      when source_node == node do
    {:noreply,
     socket
     |> assign(:upgrade_state, :success)
     |> update(:upgrade_progress, fn logs -> logs ++ [msg] end)}
  end

  def handle_info(
        {:hot_upgrade_complete, source_node, _sname, :error, msg},
        %{assigns: %{node: node, applying_upgrade: true}} = socket
      )
      when source_node == node do
    {:noreply,
     socket
     |> assign(:upgrade_state, :error)
     |> update(:upgrade_progress, fn logs -> logs ++ [msg] end)}
  end

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

      {:error, :full_deployment} ->
        {:postpone, %{hotupgrade | error: "full deployment only"}}

      {:error, {:otp_mismatch, %{running_otp: otp}}} ->
        {:postpone, %{hotupgrade | error: "wrong OTP, this installation runs OTP #{otp}"}}

      {:error, :invalid_release_file} ->
        {:postpone, %{hotupgrade | error: "not a deployex release"}}

      {:error, _reason} ->
        {:postpone, %{hotupgrade | error: "invalid release"}}
    end
  end
end
