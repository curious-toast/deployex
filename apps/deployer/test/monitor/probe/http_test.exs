defmodule Deployer.Monitor.Probe.HttpTest do
  use ExUnit.Case, async: false

  import Mock

  alias Deployer.Monitor.Probe.Http

  test "get/2 returns the response status on success" do
    with_mock Finch, [:passthrough],
      request: fn _request, Deployer.Monitor.Probe.Finch, receive_timeout: 1_000 ->
        {:ok, %Finch.Response{status: 200, headers: [], body: ""}}
      end do
      assert {:ok, 200} = Http.get("http://127.0.0.1:4001/ready", 1_000)
    end
  end

  test "get/2 returns the error reason on a transport failure" do
    with_mock Finch, [:passthrough],
      request: fn _request, Deployer.Monitor.Probe.Finch, receive_timeout: 1_000 ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end do
      assert {:error, %Mint.TransportError{reason: :timeout}} =
               Http.get("https://127.0.0.1:4001/ready", 1_000)
    end
  end
end
