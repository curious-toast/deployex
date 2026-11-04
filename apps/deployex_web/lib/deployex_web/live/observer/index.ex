defmodule DeployexWeb.ObserverLive do
  @moduledoc """
  """
  use DeployexWeb, :live_view

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
      <iframe
        src={~p"/observer/tracing?iframe=true"}
        class="block min-h-[calc(100dvh-var(--dx-topbar-height))] w-full border-0"
        title="Observer Web"
      ></iframe>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :current_path, "/embedded-observer")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Observer Web")
  end
end
