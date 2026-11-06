defmodule Deployer.ResourcesTest do
  use ExUnit.Case, async: false

  import Mox

  alias Deployer.Resources
  alias Deployer.Resources.Server
  alias Foundation.Catalog

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    name = :"resources_test_#{System.unique_integer([:positive])}"
    sname = Catalog.create_sname("myelixir")
    node = Catalog.node_info(sname).node

    %{name: name, sname: sname, node: node}
  end

  defp start_server(name), do: start_supervised!({Server, name: name, sample_interval: :manual})

  defp sample(name), do: GenServer.call(name, :sample)

  defp stub_running(sname, status \\ :running) do
    Deployer.MonitorMock
    |> stub(:list, fn -> [sname] end)
    |> stub(:state, fn ^sname -> %Deployer.Monitor{sname: sname, status: status} end)
  end

  # Answers the RPCs as an instance with this runtime counter, and as DeployEx, which samples itself too
  defp stub_node(node, runtime_ms) do
    Foundation.RpcMock
    |> stub(:multicall, fn
      nodes, :erlang, :statistics, [:runtime], _timeout ->
        Enum.map(nodes, &if(&1 == node, do: {:ok, {runtime_ms.(), 0}}, else: {:ok, {0, 0}}))

      nodes, :os, :getpid, [], _timeout ->
        Enum.map(nodes, &if(&1 == node, do: {:ok, ~c"4242"}, else: {:ok, ~c"1111"}))
    end)
  end

  defp stub_ps(output) do
    stub(Host.CommanderMock, :run, fn "ps -o pid=,rss= -p " <> _pids, [:sync, :stdout] ->
      output
    end)
  end

  test "samples the memory of a running instance", %{name: name, sname: sname, node: node} do
    stub_running(sname)
    stub_node(node, fn -> 1_000 end)
    stub_ps({:ok, [stdout: ["  4242  204800\n"]]})
    start_server(name)

    :ok = sample(name)

    assert %Resources{sname: ^sname, cpu: nil, memory: 209_715_200, sampled_at: %DateTime{}} =
             Server.get(sname, name)
  end

  test "asks an instance for its OS pid only once", %{name: name, sname: sname, node: node} do
    test_pid = self()
    stub_running(sname)

    stub(Foundation.RpcMock, :multicall, fn
      nodes, :erlang, :statistics, [:runtime], _timeout ->
        Enum.map(nodes, fn _node -> {:ok, {1_000, 0}} end)

      nodes, :os, :getpid, [], _timeout ->
        if node in nodes, do: send(test_pid, :getpid)
        Enum.map(nodes, &if(&1 == node, do: {:ok, ~c"4242"}, else: {:ok, ~c"1111"}))
    end)

    stub_ps({:ok, [stdout: ["4242 1024\n"]]})
    start_server(name)

    :ok = sample(name)
    :ok = sample(name)

    assert_received :getpid
    refute_received :getpid
  end

  test "computes the CPU share from the runtime counter between two samples", %{
    name: name,
    sname: sname,
    node: node
  } do
    counter = :counters.new(1, [])
    stub_running(sname)

    stub_node(node, fn ->
      # Each sample reads 10 seconds of CPU time more than the one before
      :counters.add(counter, 1, 10_000)
      :counters.get(counter, 1)
    end)

    stub_ps({:ok, [stdout: ["4242 1024\n"]]})
    start_server(name)

    :ok = sample(name)
    Process.sleep(20)
    :ok = sample(name)

    assert %Resources{cpu: cpu, cores: cores} = Server.get(sname, name)
    assert is_float(cpu) and cpu > 0
    assert is_integer(cores) and cores > 0
  end

  test "keeps a CPU share far below 0.01% above zero", %{name: name, sname: sname, node: node} do
    stub_running(sname)
    stub_node(node, fn -> 1_001 end)
    stub_ps({:ok, [stdout: ["4242 1024\n"]]})
    start_server(name)

    # The last sample was 100 seconds ago with 1 millisecond of CPU time less
    :sys.replace_state(name, fn state ->
      previous = %{
        node: node,
        os_pid: 4242,
        runtime_ms: 1_000,
        at_ms: System.monotonic_time(:millisecond) - 100_000
      }

      %{state | instances: %{sname => previous}}
    end)

    :ok = sample(name)

    assert %Resources{cpu: cpu} = Server.get(sname, name)
    assert cpu > 0
  end

  test "keeps the sample with no memory when ps fails", %{name: name, sname: sname, node: node} do
    stub_running(sname)
    stub_node(node, fn -> 1_000 end)
    stub_ps({:error, [exit_status: 256]})
    start_server(name)

    :ok = sample(name)

    assert %Resources{memory: nil} = Server.get(sname, name)
  end

  test "removes an instance that does not answer", %{name: name, sname: sname, node: node} do
    stub_running(sname)
    stub_node(node, fn -> 1_000 end)
    stub_ps({:ok, [stdout: ["4242 1024\n"]]})
    start_server(name)

    :ok = sample(name)
    assert %Resources{} = Server.get(sname, name)

    stub(Foundation.RpcMock, :multicall, fn nodes, _module, _function, _args, _timeout ->
      Enum.map(nodes, fn _node -> {:error, {:erpc, :timeout}} end)
    end)

    send(Process.whereis(name), :sample)
    :sys.get_state(name)

    assert Server.get(sname, name) == nil
  end

  test "skips an instance that is not running, and samples DeployEx itself", %{
    name: name,
    sname: sname
  } do
    stub_running(sname, :starting)
    stub_node(:none, fn -> 0 end)
    stub_ps({:ok, [stdout: ["1111 2048\n"]]})
    start_server(name)

    :ok = sample(name)

    assert Server.get(sname, name) == nil
    assert %Resources{sname: "deployex", memory: 2_097_152} = Server.get("deployex", name)
  end

  test "a node that does not answer delays no other node", %{name: name, sname: sname, node: node} do
    other = Catalog.create_sname("myelixir")
    other_node = Catalog.node_info(other).node

    Deployer.MonitorMock
    |> stub(:list, fn -> [sname, other] end)
    |> stub(:state, fn sname -> %Deployer.Monitor{sname: sname, status: :running} end)

    # One call for every node, and only the nodes that answered are asked for their OS pid
    expect(Foundation.RpcMock, :multicall, fn nodes, :erlang, :statistics, [:runtime], _timeout ->
      assert Enum.sort(nodes) == Enum.sort([Node.self(), node, other_node])
      Enum.map(nodes, &if(&1 == other_node, do: {:error, {:erpc, :timeout}}, else: {:ok, {0, 0}}))
    end)

    expect(Foundation.RpcMock, :multicall, fn nodes, :os, :getpid, [], _timeout ->
      assert Enum.sort(nodes) == Enum.sort([Node.self(), node])
      Enum.map(nodes, &if(&1 == node, do: {:ok, ~c"4242"}, else: {:ok, ~c"1111"}))
    end)

    stub_ps({:ok, [stdout: ["4242 1024\n"]]})
    start_server(name)

    :ok = sample(name)

    assert %Resources{memory: 1_048_576} = Server.get(sname, name)
    assert Server.get(other, name) == nil
  end

  test "returns nil with no server" do
    assert Server.get("myelixir-abc", :no_such_resources_server) == nil
    assert Resources.get("myelixir-abc") == nil
  end
end
