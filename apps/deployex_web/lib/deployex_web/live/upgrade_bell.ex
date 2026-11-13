defmodule DeployexWeb.UpgradeBellLive do
  @moduledoc """
  The DeployEx self-upgrade in the bell, while it runs. It shows on every page and for every viewer, whatever
  started the upgrade: the Hot Upgrade page, another tab or `deployex.sh --hot-upgrade`. The bell gets a dot,
  and its panel gets a row with the steps that links to the Hot Upgrade page.

  It is a sticky nested LiveView in the layout, like the dock, so it keeps its state across pages.
  """
  use DeployexWeb, :live_view

  import DeployexWeb.HotUpgrade.Events, only: [from_this_host?: 1]

  alias Deployer.HotUpgrade
  alias Deployer.HotUpgrade.Progress
  alias DeployexWeb.HotUpgrade.Steps
  alias DeployexWeb.UI.Icons
  alias DeployexWeb.UI.StepLeds

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: HotUpgrade.deployex_subscribe()

    {:ok, assign(socket, :progress, HotUpgrade.deployex_progress()), layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.link
      :if={Progress.running?(@progress)}
      id="upgrade-bell-run"
      navigate={~p"/hotupgrade"}
      class="dx-nitem dx-nitem-run"
    >
      <Icons.icon name="fire" class="dx-ico mt-0.5 size-[15px]" style="color: var(--dx-hot-text)" />
      <span class="min-w-0 flex-1">
        <span class="dx-nt">
          <b>DeployEx hot upgrade</b>
          <span class="dx-mono">{@progress.from_version} → {@progress.to_version}</span>
        </span>
        <span class="dx-nd">{Steps.line(@progress)}</span>
        <StepLeds.row id="upgrade-bell-leds" steps={Steps.states(@progress)} compact />
      </span>
    </.link>
    """
  end

  @impl true
  def handle_info(event, socket) when from_this_host?(event),
    do: {:noreply, assign(socket, :progress, HotUpgrade.deployex_progress())}

  def handle_info(_message, socket), do: {:noreply, socket}
end
