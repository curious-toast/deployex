defmodule DeployexWeb.Instances do
  @moduledoc """
  The monitored instances of this host, as the pages name them: an instance's app and language, and an app's
  running instances. The app comes from the catalog entry of the sname, not from its name prefix.
  """

  alias Foundation.Catalog

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
  Returns this host's name.
  """
  @spec host_name() :: String.t()
  def host_name do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
