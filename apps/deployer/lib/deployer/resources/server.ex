defmodule Deployer.Resources.Server do
  @moduledoc """
  Samples each running instance every few seconds and keeps the result in a protected ETS table.

  Each sample sends one RPC to every instance at the same time, so a hung node delays it by at most one
  timeout. A node that does not answer is skipped for that sample, and its entry is removed.
  """
  use GenServer

  alias Deployer.Monitor
  alias Deployer.Resources
  alias Foundation.Catalog
  alias Foundation.Rpc
  alias Host.Commander

  @sample_interval :timer.seconds(5)
  @rpc_timeout 1_000

  ### ==========================================================================
  ### GenServer callbacks
  ### ==========================================================================
  def start_link(args \\ []) do
    name = Keyword.get(args, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(args, :name, name), name: name)
  end

  @impl true
  def init(args) do
    name = Keyword.fetch!(args, :name)
    :ets.new(name, [:set, :protected, :named_table])

    interval = Keyword.get(args, :sample_interval, @sample_interval)
    schedule(interval)

    {:ok, %{table: name, interval: interval, instances: %{}}}
  end

  @impl true
  def handle_info(:sample, %{table: table, interval: interval} = state) do
    state = sample(state)

    # Entries for instances that stopped, or did not answer this time, are removed
    for {sname, _resources} <- :ets.tab2list(table), not Map.has_key?(state.instances, sname) do
      :ets.delete(table, sname)
    end

    schedule(interval)
    {:noreply, state}
  end

  # Samples now and replies when the table holds the result
  @impl true
  def handle_call(:sample, _from, state), do: {:reply, :ok, sample(state)}

  ### ==========================================================================
  ### Public APIs
  ### ==========================================================================

  @doc """
  Returns the last sample of an instance, or nil when it has none or the server does not run.
  """
  @spec get(sname :: String.t(), name :: atom()) :: Resources.t() | nil
  def get(sname, name \\ __MODULE__) do
    with table when table != :undefined <- :ets.whereis(name),
         [{^sname, resources}] <- :ets.lookup(table, sname) do
      resources
    else
      _ -> nil
    end
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================
  defp schedule(:manual), do: :ok
  defp schedule(interval), do: Process.send_after(self(), :sample, interval)

  defp sample(%{table: table, instances: previous} = state) do
    now_ms = System.monotonic_time(:millisecond)
    running = running_instances()
    runtimes = rpc_all(Enum.map(running, &elem(&1, 1)), :erlang, :statistics, [:runtime])
    answered = Enum.filter(running, fn {_sname, node} -> Map.has_key?(runtimes, node) end)
    os_pids = os_pids(answered, previous)

    instances =
      for {sname, node} <- answered, Map.has_key?(os_pids, node), into: %{} do
        {runtime_ms, _since_last_call} = Map.fetch!(runtimes, node)

        {sname,
         %{node: node, os_pid: Map.fetch!(os_pids, node), runtime_ms: runtime_ms, at_ms: now_ms}}
      end

    memory = read_memory(instances)
    # The runtime can report :unknown, and the CPU share then counts one core
    cores =
      case :erlang.system_info(:logical_processors_online) do
        cores when is_integer(cores) and cores > 0 -> cores
        _unknown -> 1
      end

    sampled_at = DateTime.utc_now(:second)

    Enum.each(instances, fn {sname, instance} ->
      resources = %Resources{
        sname: sname,
        cpu: cpu_percent(instance, Map.get(previous, sname), cores),
        cores: cores,
        memory: Map.get(memory, instance.os_pid),
        sampled_at: sampled_at
      }

      :ets.insert(table, {sname, resources})
    end)

    %{state | instances: instances}
  end

  # DeployEx samples itself too, for its own row
  defp running_instances do
    Enum.reduce(Monitor.list(), [{"deployex", Node.self()}], fn sname, acc ->
      with true <- sname |> Monitor.state() |> Monitor.serving?(),
           %{node: node} <- Catalog.node_info(sname) do
        [{sname, node} | acc]
      else
        _ -> acc
      end
    end)
  end

  # The OS pid of an instance does not change while its node stays the same, so only a new node is asked
  defp os_pids(instances, previous) do
    {known, new} =
      Enum.split_with(instances, fn {sname, node} ->
        match?(%{node: ^node}, Map.get(previous, sname))
      end)

    asked =
      new
      |> Enum.map(&elem(&1, 1))
      |> rpc_all(:os, :getpid, [])
      |> Map.new(fn {node, os_pid} -> {node, os_pid |> to_string() |> String.to_integer()} end)

    Map.merge(Map.new(known, fn {sname, node} -> {node, previous[sname].os_pid} end), asked)
  end

  # The value of each node that answered
  defp rpc_all([], _module, _function, _args), do: %{}

  defp rpc_all(nodes, module, function, args) do
    nodes
    |> Enum.zip(Rpc.multicall(nodes, module, function, args, @rpc_timeout))
    |> Enum.flat_map(fn
      {node, {:ok, value}} -> [{node, value}]
      _failed -> []
    end)
    |> Map.new()
  end

  # CPU time of all the BEAM's threads over the wall time since the last sample, as a share of every core
  defp cpu_percent(
         %{node: node, runtime_ms: runtime_ms, at_ms: at_ms},
         %{node: node} = previous,
         cores
       )
       when at_ms > previous.at_ms and runtime_ms >= previous.runtime_ms do
    Float.round((runtime_ms - previous.runtime_ms) / ((at_ms - previous.at_ms) * cores) * 100, 4)
  end

  defp cpu_percent(_instance, _previous, _cores), do: nil

  # One ps call for every instance. The resident memory comes in kilobytes
  defp read_memory(instances) when map_size(instances) == 0, do: %{}

  defp read_memory(instances) do
    pids = instances |> Map.values() |> Enum.map_join(",", & &1.os_pid)

    case Commander.run("ps -o pid=,rss= -p #{pids}", [:sync, :stdout]) do
      {:ok, output} -> parse_ps(output)
      {:error, output} when is_list(output) -> parse_ps(output)
      _ -> %{}
    end
  end

  defp parse_ps(output) do
    output
    |> Keyword.get(:stdout, [])
    |> Enum.join()
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case line |> String.split() |> Enum.map(&Integer.parse/1) do
        [{pid, ""}, {rss_kb, ""}] -> Map.put(acc, pid, rss_kb * 1024)
        _ -> acc
      end
    end)
  end
end
