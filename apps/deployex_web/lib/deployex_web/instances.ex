defmodule DeployexWeb.Instances do
  @moduledoc """
  The monitored instances of this host, as the pages name them: an instance's app and language, and an app's
  running instances. The app comes from the catalog entry of the sname, not from its name prefix.
  """

  alias Foundation.Catalog
  alias Foundation.Rpc

  @rpc_timeout 1_000

  @doc """
  Returns the app of an instance, or nil when the target is not an instance, like `deployex` or the host.
  """
  @spec app(String.t()) :: String.t() | nil
  def app("deployex"), do: nil

  def app(target) do
    case Catalog.node_info(target) do
      %{name: name} when is_binary(name) and name not in ["", "deployex"] -> name
      _ -> nil
    end
  end

  @doc """
  Returns the running instances of an app.
  """
  @spec of_app(String.t()) :: [String.t()]
  def of_app(app) do
    for sname <- Enum.map(Deployer.Monitor.list(), &to_string/1), app(sname) == app, do: sname
  end

  @doc """
  Returns the language of an app or an instance: elixir, erlang or gleam, and deployex for DeployEx.
  """
  @spec language(String.t()) :: String.t()
  def language("deployex"), do: "deployex"

  def language(name_or_sname) do
    case Catalog.node_info(name_or_sname) do
      %{language: language} when language in ["elixir", "erlang", "gleam"] ->
        language

      _ ->
        case Enum.find(Catalog.applications(), &(&1.name == name_or_sname)) do
          %{language: language} -> language
          _ -> "elixir"
        end
    end
  end

  @doc """
  Returns how a node takes part in the OTP distribution: its protocol, whether it runs hidden, and the
  nodes it is connected to, grouped as DeployEx, its app, other apps, and other nodes. The app is nil for
  DeployEx. Returns nil when the node does not answer.
  """
  @spec distribution(node(), String.t() | nil) :: map() | nil
  def distribution(node, app) do
    with arguments when is_list(arguments) <-
           Rpc.call(node, :init, :get_arguments, [], @rpc_timeout),
         nodes when is_list(nodes) <-
           Rpc.call(node, :erlang, :nodes, [:connected, %{node_type: true}], @rpc_timeout) do
      tls? = arguments |> Keyword.get_values(:proto_dist) |> Enum.concat() |> Enum.any?(&tls?/1)

      %{
        protocol: if(tls?, do: "TLS", else: "TCP"),
        hidden: Keyword.has_key?(arguments, :hidden),
        groups: groups(nodes, app)
      }
    else
      _no_answer -> nil
    end
  end

  defp tls?(proto), do: proto |> to_string() |> String.contains?("tls")

  defp groups(nodes, app) do
    by_group =
      Enum.group_by(
        nodes,
        fn {connected, %{node_type: type}} ->
          sname = connected |> Atom.to_string() |> String.split("@") |> hd()

          cond do
            connected == Node.self() -> "DeployEx"
            app != nil and app(sname) == app -> "Same app"
            app(sname) != nil -> "Other apps"
            type == :hidden -> "Hidden nodes"
            true -> "Other nodes"
          end
        end,
        fn {connected, _info} -> connected |> Atom.to_string() |> String.split("@") |> hd() end
      )

    for group <- ["DeployEx", "Same app", "Other apps", "Hidden nodes", "Other nodes"],
        names = by_group[group],
        do: {group, Enum.sort(names)}
  end

  @doc """
  Returns this host's name.
  """
  @spec host_name() :: String.t()
  def host_name do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
