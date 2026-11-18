defmodule Deployer.Monitor.Probe do
  @moduledoc """
  Checks whether a started application satisfies its readiness configuration.

  The `:otp` check reads the boot status of the node, which needs nothing from the application.
  A node that is not up yet, or does not answer in time, is not ready.

  A release reports `{:started, :started}` only after its boot script has started every
  application, so that is what it must answer.

  A Gleam application boots from `-eval`, and `gleam@@main:run/1` blocks there until the
  application ends, so a healthy node answers `{:starting, :started}` for its whole life. The check
  then only says that the node is up and answering, not that `main` finished its own setup.

  The `:http` check requests `<scheme>://127.0.0.1:<port><path>` on the instance and expects a
  2xx response, with the port looked up from the instance's ports by `port_key`. An instance
  whose ports do not have that key is not ready.
  """

  alias Deployer.Monitor.Probe.Http
  alias Foundation.Rpc
  alias Foundation.Yaml.Ports
  alias Foundation.Yaml.Readiness

  @rpc_timeout 1_000
  @http_timeout 1_000

  ### ==========================================================================
  ### Public APIs
  ### ==========================================================================

  @doc """
  Return true when the application running on the node is ready.
  """
  @spec ready?(
          readiness :: Readiness.t(),
          node :: node(),
          language :: String.t() | nil,
          ports :: [Ports.t()]
        ) :: boolean()
  def ready?(%Readiness{type: :timeout}, _node, _language, _ports), do: true

  def ready?(%Readiness{type: :otp}, node, language, _ports),
    do: booted?(language, Rpc.call(node, :init, :get_status, [], @rpc_timeout))

  def ready?(%Readiness{type: :http} = readiness, _node, _language, ports),
    do: http_ready?(readiness, ports)

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================
  defp booted?(_language, {:started, :started}), do: true
  defp booted?("gleam", {:starting, :started}), do: true
  defp booted?(_language, _status), do: false

  defp http_ready?(%Readiness{port_key: port_key} = readiness, ports) do
    case find_port(ports, port_key) do
      nil -> false
      port -> request_ready?(readiness, port)
    end
  end

  defp request_ready?(%Readiness{scheme: scheme, path: path}, port) do
    case Http.get("#{scheme}://127.0.0.1:#{port}#{path}", @http_timeout) do
      {:ok, status} when status in 200..299 -> true
      _ -> false
    end
  end

  defp find_port(ports, key),
    do: Enum.find_value(ports, fn port -> port.key == key && port.base end)
end
