defmodule Deployer.Installer.DeployexShTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @installer Path.expand("../../../../devops/installer/deployex.sh", __DIR__)
  @url "s3://releases-bucket/deployex/0.10.1/checksum.txt"

  # Stands in for aws and wget: records its arguments, one per line. With FAKE_FAIL set, it fails
  # with the multi-line output the AWS CLI gave for a missing profile in a live run
  @fake_cli ~S"""
  #!/bin/bash
  printf '%s\n' "$@" > "${FAKE_ARGS_DIR}/$(basename "$0")"
  if [[ -n "${FAKE_FAIL}" ]]; then
    printf '\naws: [ERROR]: The config profile (deployex) could not be found\n' >&2
    exit 1
  fi
  """

  # The installer parses its arguments when it runs, so load only the function under test.
  # aws_region is set here, since the BEAM drops an empty variable from the environment.
  @run_fetch ~S"""
  eval "$(sed -n '/^fetch_release_file() {$/,/^}$/p' "${INSTALLER}")"
  aws_region="${REGION}"
  fetch_release_file "${URL}" "${DEST}" 2>"${ERR}"
  """

  setup %{tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)

    for name <- ["aws", "wget"] do
      path = Path.join(bin, name)
      File.write!(path, @fake_cli)
      File.chmod!(path, 0o755)
    end

    %{bin: bin, dest: Path.join(tmp_dir, "checksum.txt")}
  end

  test "passes --region when aws_region is set", context do
    result = fetch_release_file(context, @url, [{"REGION", "eu-west-1"}])

    assert result.status == 0
    assert result.stderr == ""

    assert result.aws ==
             ~w(s3 cp --only-show-errors --cli-connect-timeout 30 --region eu-west-1) ++
               [@url, context.dest]
  end

  test "leaves --region out when aws_region is empty or null", context do
    for region <- ["", "null"] do
      result = fetch_release_file(context, @url, [{"REGION", region}])

      assert result.status == 0

      assert result.aws ==
               ~w(s3 cp --only-show-errors --cli-connect-timeout 30) ++ [@url, context.dest]
    end
  end

  test "a failure gives one error line with the URL and the reason, and a non-zero exit",
       context do
    result = fetch_release_file(context, @url, [{"REGION", "eu-west-1"}, {"FAKE_FAIL", "1"}])

    assert result.status != 0

    assert result.stderr ==
             "Error: cannot read #{@url}: aws: [ERROR]: The config profile (deployex) could not be found\n"
  end

  test "an https URL is read with wget, not the AWS CLI", context do
    url = "https://github.com/deployex/deployex/releases/download/0.10.1/checksum.txt"

    result = fetch_release_file(context, url, [])

    assert result.status == 0
    assert result.wget == ["--timeout=30", "--tries=3", "-O", context.dest, url]
    assert result.aws == nil
  end

  describe "release_file_name" do
    @run_name ~S"""
    eval "$(sed -n '/^release_file_name() {$/,/^}$/p' "${INSTALLER}")"
    release_file_name "${OS_TARGET}" 28 2>"${ERR}"
    """

    test "an x86_64 host gets the asset name without an architecture", context do
      assert release_file_name(context, "x86_64") ==
               {"deployex-ubuntu-24.04-otp-28.tar.gz\n", 0, ""}
    end

    test "an aarch64 host gets the arm64 asset", context do
      assert release_file_name(context, "aarch64") ==
               {"deployex-ubuntu-24.04-arm64-otp-28.tar.gz\n", 0, ""}
    end

    test "the amazon-linux-2023 os_target gets the Amazon Linux assets", context do
      assert release_file_name(context, "x86_64", "amazon-linux-2023") ==
               {"deployex-amazon-linux-2023-otp-28.tar.gz\n", 0, ""}

      assert release_file_name(context, "aarch64", "amazon-linux-2023") ==
               {"deployex-amazon-linux-2023-arm64-otp-28.tar.gz\n", 0, ""}
    end

    test "another architecture fails with the reason", context do
      {name, status, stderr} = release_file_name(context, "riscv64")

      assert name == ""
      assert status != 0

      assert stderr ==
               "Error: no DeployEx release for the riscv64 architecture, only x86_64 and aarch64\n"
    end
  end

  describe "remove_deployex_user" do
    @run_remove_user ~S"""
    eval "$(sed -n '/^remove_deployex_user() {$/,/^}$/p' "${INSTALLER}")"
    remove_deployex_user
    """

    setup %{bin: bin} do
      for name <- ["id", "getent", "userdel", "groupdel", "deluser", "delgroup"] do
        path = Path.join(bin, name)
        File.write!(path, @fake_cli)
        File.chmod!(path, 0o755)
      end

      :ok
    end

    test "removes the user and the group with userdel and groupdel", context do
      assert remove_deployex_user(context, []) == 0

      assert recorded_args(context.tmp_dir, "userdel") == ["--remove", "deployex"]
      assert recorded_args(context.tmp_dir, "groupdel") == ["deployex"]
      assert recorded_args(context.tmp_dir, "deluser") == nil
      assert recorded_args(context.tmp_dir, "delgroup") == nil
    end

    test "removes nothing when the user and the group do not exist", context do
      assert remove_deployex_user(context, [{"FAKE_FAIL", "1"}]) == 0

      assert recorded_args(context.tmp_dir, "id") == ["deployex"]
      assert recorded_args(context.tmp_dir, "userdel") == nil
      assert recorded_args(context.tmp_dir, "groupdel") == nil
    end
  end

  test "stops with the reason when yq is not installed", %{tmp_dir: tmp_dir} do
    config = Path.join(tmp_dir, "deployex.yaml")
    File.write!(config, "version: \"0.10.1\"\n")

    # An empty PATH has no yq. The installer reaches the check with shell builtins only
    {output, status} =
      System.cmd(System.find_executable("bash"), [@installer, "--update", config],
        env: [{"PATH", Path.join(tmp_dir, "empty")}]
      )

    assert status == 1

    assert output ==
             "Error: yq is required to read #{config}. Install it first, for example: dnf install yq, or apt-get install yq\n"
  end

  defp release_file_name(%{tmp_dir: tmp_dir, bin: bin}, arch, os_target \\ "ubuntu-24.04") do
    err = Path.join(tmp_dir, "stderr")
    uname = Path.join(bin, "uname")
    File.write!(uname, "#!/bin/bash\necho #{arch}\n")
    File.chmod!(uname, 0o755)

    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH")},
      {"INSTALLER", @installer},
      {"OS_TARGET", os_target},
      {"ERR", err}
    ]

    {output, status} = System.cmd("bash", ["-c", @run_name], env: env)
    {output, status, File.read!(err)}
  end

  defp remove_deployex_user(%{tmp_dir: tmp_dir, bin: bin}, env) do
    env =
      Map.merge(
        %{
          "PATH" => bin <> ":" <> System.get_env("PATH"),
          "INSTALLER" => @installer,
          "FAKE_ARGS_DIR" => tmp_dir,
          "FAKE_FAIL" => nil
        },
        Map.new(env)
      )

    {_output, status} = System.cmd("bash", ["-c", @run_remove_user], env: Enum.to_list(env))
    status
  end

  defp fetch_release_file(%{tmp_dir: tmp_dir, bin: bin, dest: dest}, url, env) do
    err = Path.join(tmp_dir, "stderr")
    Enum.each(["aws", "wget"], &File.rm(Path.join(tmp_dir, &1)))

    # nil removes a variable, so the parent environment cannot set REGION or FAKE_FAIL
    env =
      Map.merge(
        %{
          "PATH" => bin <> ":" <> System.get_env("PATH"),
          "INSTALLER" => @installer,
          "URL" => url,
          "DEST" => dest,
          "ERR" => err,
          "FAKE_ARGS_DIR" => tmp_dir,
          "REGION" => nil,
          "FAKE_FAIL" => nil
        },
        Map.new(env)
      )

    {_output, status} = System.cmd("bash", ["-c", @run_fetch], env: Enum.to_list(env))

    %{
      status: status,
      stderr: File.read!(err),
      aws: recorded_args(tmp_dir, "aws"),
      wget: recorded_args(tmp_dir, "wget")
    }
  end

  defp recorded_args(tmp_dir, name) do
    case File.read(Path.join(tmp_dir, name)) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, :enoent} -> nil
    end
  end
end
