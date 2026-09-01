defmodule Examples.Plugins.LocalScriptRunner.ScriptRunnerTest do
  use ExUnit.Case

  alias Examples.Plugins.Shared.ScriptSandbox

  describe "validate_path/2" do
    test "rejects traversal segments" do
      allowed = Path.join(System.tmp_dir!(), "sandbox-#{System.unique_integer([:positive])}")
      File.mkdir_p!(allowed)

      assert {:error, :path_traversal_rejected} =
               ScriptSandbox.validate_path("../../etc/passwd", allowed)
    end

    test "rejects absolute paths outside the allowed directory" do
      allowed = Path.join(System.tmp_dir!(), "sandbox-#{System.unique_integer([:positive])}")
      File.mkdir_p!(allowed)

      assert {:error, :outside_allowed_directory} =
               ScriptSandbox.validate_path("/etc/passwd", allowed)
    end
  end

  describe "execute/3" do
    test "runs a helper script and parses JSON stdout" do
      cond do
        System.find_executable("sh") == nil ->
          IO.warn("skipping ScriptSandbox JSON test: sh not installed")

        System.find_executable("python3") == nil ->
          IO.warn("skipping ScriptSandbox JSON test: python3 not installed")

        true ->
          allowed = Path.join(System.tmp_dir!(), "exec-#{System.unique_integer([:positive])}")
          File.mkdir_p!(allowed)

          script_path = Path.join(allowed, "identity.py")

          File.write!(script_path, """
          import json
          import sys
          data = json.load(sys.stdin)
          json.dump(data, sys.stdout)
          """)

          assert {:ok, %{"value" => 7}} =
                   ScriptSandbox.execute(
                     "identity.py",
                     %{"value" => 7},
                     allowed_scripts_directory: allowed
                   )
      end
    end

    test "returns error when helper script exits non-zero" do
      cond do
        System.find_executable("sh") == nil ->
          IO.warn("skipping ScriptSandbox failure test: sh not installed")

        System.find_executable("bash") == nil ->
          IO.warn("skipping ScriptSandbox failure test: bash not installed")

        true ->
          allowed = Path.join(System.tmp_dir!(), "fail-#{System.unique_integer([:positive])}")
          File.mkdir_p!(allowed)

          script_path = Path.join(allowed, "fail.sh")

          File.write!(script_path, """
          #!/usr/bin/env bash
          echo '{"failed":true}' >&2
          exit 1
          """)

          assert {:error, {:script_failed, exit_status, _output}} =
                   ScriptSandbox.execute(
                     "fail.sh",
                     %{"input" => true},
                     allowed_scripts_directory: allowed
                   )

          refute exit_status == 0
      end
    end

    test "returns error when script exceeds timeout" do
      cond do
        System.find_executable("sh") == nil ->
          IO.warn("skipping ScriptSandbox timeout test: sh not installed")

        System.find_executable("bash") == nil ->
          IO.warn("skipping ScriptSandbox timeout test: bash not installed")

        true ->
          allowed = Path.join(System.tmp_dir!(), "timeout-#{System.unique_integer([:positive])}")
          File.mkdir_p!(allowed)

          script_path = Path.join(allowed, "slow.sh")

          File.write!(script_path, """
          #!/usr/bin/env bash
          sleep 10
          echo '{"done":true}'
          """)

          File.chmod!(script_path, 0o755)

          assert {:error, :execution_timeout} =
                   ScriptSandbox.execute(
                     "slow.sh",
                     %{"input" => true},
                     allowed_scripts_directory: allowed,
                     timeout_milliseconds: 500
                   )
      end
    end

    test "runs a Node.js helper script and parses JSON stdout" do
      cond do
        System.find_executable("sh") == nil ->
          IO.warn("skipping ScriptSandbox Node.js test: sh not installed")

        System.find_executable("node") == nil ->
          IO.warn("skipping ScriptSandbox Node.js test: node not installed")

        true ->
          allowed = Path.join(System.tmp_dir!(), "exec-node-#{System.unique_integer([:positive])}")
          File.mkdir_p!(allowed)

          script_path = Path.join(allowed, "identity.js")

          File.write!(script_path, """
          const fs = require("fs");
          const data = JSON.parse(fs.readFileSync(0, "utf8"));
          process.stdout.write(JSON.stringify(data));
          """)

          assert {:ok, %{"value" => 7}} =
                   ScriptSandbox.execute(
                     "identity.js",
                     %{"value" => 7},
                     allowed_scripts_directory: allowed
                   )
      end
    end
  end
end
