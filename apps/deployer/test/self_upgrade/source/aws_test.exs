defmodule Deployer.SelfUpgrade.Source.AwsTest do
  use ExUnit.Case, async: true

  alias Deployer.SelfUpgrade.Source.Aws

  defmodule FakeOk do
    def token, do: {:ok, "tok"}
    def tag("tok"), do: {:ok, "0.9.15"}
  end

  defmodule FakeNoTag do
    def token, do: {:ok, "tok"}
    def tag("tok"), do: {:error, :not_found}
  end

  setup do
    on_exit(fn -> Application.delete_env(:deployer, Aws) end)
  end

  test "returns the tag value" do
    Application.put_env(:deployer, Aws, client: FakeOk)
    assert {:ok, "0.9.15"} = Aws.desired_version()
  end

  test "returns :none when the tag is missing" do
    Application.put_env(:deployer, Aws, client: FakeNoTag)
    assert :none = Aws.desired_version()
  end
end
