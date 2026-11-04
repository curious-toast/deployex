defmodule Foundation.Rpc do
  @moduledoc """
  This module will provide rpc abstraction
  """

  @behaviour Foundation.Rpc.Adapter

  ### ==========================================================================
  ### Callback function implementation
  ### ==========================================================================

  @doc """
  Run the passed commands and link the process with the genserver calling
  gen_server for supervision
  """
  @impl true
  @spec call(
          node :: atom,
          module :: module,
          function :: atom,
          args :: list,
          timeout :: 0..4_294_967_295 | :infinity
        ) :: any() | {:badrpc, any()}
  def call(node, module, function, args, timeout),
    do: default().call(node, module, function, args, timeout)

  @doc """
  Runs the function on every node at the same time, and returns one result for each node, in the order of
  the nodes. The timeout applies to all the nodes together.
  """
  @impl true
  @spec multicall(
          nodes :: [atom],
          module :: module,
          function :: atom,
          args :: list,
          timeout :: 0..4_294_967_295 | :infinity
        ) :: [{:ok, any()} | {:error | :exit | :throw, any()}]
  def multicall(nodes, module, function, args, timeout),
    do: default().multicall(nodes, module, function, args, timeout)

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================
  defp default, do: Application.fetch_env!(:foundation, __MODULE__)[:adapter]
end
