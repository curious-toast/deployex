defmodule Deployer.Monitor.ProbeTest do
  use ExUnit.Case, async: false

  import Mock
  import Mox

  setup :verify_on_exit!

  alias Deployer.Monitor.Probe
  alias Deployer.Monitor.Probe.Http
  alias Foundation.Yaml.Ports
  alias Foundation.Yaml.Readiness

  @node :"myelixir-abc123@host"

  test "timeout is ready without asking the node" do
    expect(Foundation.RpcMock, :call, 0, fn _node, _module, _function, _args, _timeout -> nil end)

    assert Probe.ready?(%Readiness{type: :timeout}, @node, "elixir", [])
  end

  test "otp is ready when the boot of the node finished" do
    expect(Foundation.RpcMock, :call, fn @node, :init, :get_status, [], 1_000 ->
      {:started, :started}
    end)

    assert Probe.ready?(%Readiness{type: :otp}, @node, "elixir", [])
  end

  for status <- [
        {:starting, :applications_loaded},
        {:starting, :started},
        {:stopping, :started},
        {:badrpc, :nodedown},
        {:badrpc, :timeout}
      ] do
    test "otp is not ready when the node answers #{inspect(status)}" do
      expect(Foundation.RpcMock, :call, fn @node, :init, :get_status, [], 1_000 ->
        unquote(Macro.escape(status))
      end)

      refute Probe.ready?(%Readiness{type: :otp}, @node, "elixir", [])
    end
  end

  # Boots from -eval, which only returns when the application ends
  test "otp on gleam is ready while the node answers from its -eval" do
    expect(Foundation.RpcMock, :call, fn @node, :init, :get_status, [], 1_000 ->
      {:starting, :started}
    end)

    assert Probe.ready?(%Readiness{type: :otp}, @node, "gleam", [])
  end

  for status <- [{:stopping, :started}, {:badrpc, :nodedown}, {:badrpc, :timeout}] do
    test "otp on gleam is not ready when the node answers #{inspect(status)}" do
      expect(Foundation.RpcMock, :call, fn @node, :init, :get_status, [], 1_000 ->
        unquote(Macro.escape(status))
      end)

      refute Probe.ready?(%Readiness{type: :otp}, @node, "gleam", [])
    end
  end

  describe "http" do
    @readiness %Readiness{type: :http, scheme: "http", port_key: "PORT", path: "/ready"}
    @ports [%Ports{key: "PORT", base: 4001}, %Ports{key: "OTHER", base: 9000}]

    test "requests the instance's port, by key, and passes on a 2xx response" do
      with_mock Http, get: fn "http://127.0.0.1:4001/ready", 1_000 -> {:ok, 200} end do
        assert Probe.ready?(@readiness, @node, "elixir", @ports)
      end
    end

    test "builds the url from scheme, port and path" do
      readiness = %{@readiness | scheme: "https", path: "/healthz"}

      with_mock Http, get: fn "https://127.0.0.1:4001/healthz", 1_000 -> {:ok, 204} end do
        assert Probe.ready?(readiness, @node, "elixir", @ports)
      end
    end

    for status <- [301, 302, 400, 404, 500, 503] do
      test "is not ready on a #{status} response" do
        with_mock Http, get: fn _url, _timeout -> {:ok, unquote(status)} end do
          refute Probe.ready?(@readiness, @node, "elixir", @ports)
        end
      end
    end

    test "is not ready when the request fails" do
      with_mock Http, get: fn _url, _timeout -> {:error, :timeout} end do
        refute Probe.ready?(@readiness, @node, "elixir", @ports)
      end
    end

    test "is not ready when the instance's ports have no port_key match" do
      with_mock Http, get: fn _url, _timeout -> {:ok, 200} end do
        refute Probe.ready?(@readiness, @node, "elixir", [%Ports{key: "OTHER", base: 9000}])

        assert_not_called(Http.get(:_, :_))
      end
    end
  end
end
