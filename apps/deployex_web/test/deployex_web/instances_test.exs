defmodule DeployexWeb.InstancesTest do
  use ExUnit.Case, async: false

  import Mox

  alias DeployexWeb.Instances
  alias Foundation.Catalog

  setup [:set_mox_global, :verify_on_exit!]

  test "the app and the language of an instance come from the catalog" do
    sname = Catalog.create_sname("myelixir")

    assert Instances.app(sname) == "myelixir"
    assert Instances.app("deployex") == nil
    assert Instances.app("not-an-instance") == nil
    assert Instances.language("deployex") == "deployex"
  end

  test "the distribution names the protocol and groups the connected nodes" do
    sname = Catalog.create_sname("myelixir")
    sibling = Catalog.create_sname("myelixir")
    other = Catalog.create_sname("myerlang")
    node = Catalog.node_info(sname).node
    [sibling_node, other_node] = Enum.map([sibling, other], &Catalog.node_info(&1).node)

    stub(Foundation.RpcMock, :call, fn
      ^node, :init, :get_arguments, [], _timeout ->
        [proto_dist: [[~c"inet_tls"]], hidden: [], name: [~c"x"]]

      ^node, :erlang, :nodes, [:connected, %{node_type: true}], _timeout ->
        [
          {Node.self(), %{node_type: :visible}},
          {sibling_node, %{node_type: :visible}},
          {other_node, %{node_type: :visible}},
          {:"remsh-1@host", %{node_type: :hidden}},
          {:tool@host, %{node_type: :visible}}
        ]
    end)

    assert %{protocol: "TLS", hidden: true, groups: groups} =
             Instances.distribution(node, "myelixir")

    self_sname = Node.self() |> Atom.to_string() |> String.split("@") |> hd()

    assert groups == [
             {"DeployEx", [self_sname]},
             {"Same app", [sibling]},
             {"Other apps", [other]},
             {"Hidden nodes", ["remsh-1"]},
             {"Other nodes", ["tool"]}
           ]
  end

  test "a node with the default protocol is TCP, and one that does not answer has no distribution" do
    stub(Foundation.RpcMock, :call, fn
      :a@host, :init, :get_arguments, [], _timeout -> [name: [~c"a"]]
      :a@host, :erlang, :nodes, _args, _timeout -> []
      :b@host, _module, _function, _args, _timeout -> {:badrpc, :nodedown}
    end)

    assert %{protocol: "TCP", hidden: false, groups: []} = Instances.distribution(:a@host, nil)
    assert Instances.distribution(:b@host, nil) == nil
  end
end
