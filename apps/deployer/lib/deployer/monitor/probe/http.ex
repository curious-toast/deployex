defmodule Deployer.Monitor.Probe.Http do
  @moduledoc """
  Requests the readiness probe's endpoint.

  The request goes out through `Deployer.Monitor.Probe.Finch`, a pool that does not verify TLS
  certificates, because the probe connects to the application by IP address rather than by its
  domain name, and the certificate is issued for the domain. Finch does not follow redirects, so
  a 3xx response comes back as that status rather than as the response it points to.
  """

  @spec get(url :: String.t(), timeout :: non_neg_integer()) ::
          {:ok, status :: non_neg_integer()} | {:error, any()}
  def get(url, timeout) do
    case :get
         |> Finch.build(url)
         |> Finch.request(Deployer.Monitor.Probe.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end
end
