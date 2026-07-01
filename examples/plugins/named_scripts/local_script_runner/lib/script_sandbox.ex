defmodule Examples.Plugins.LocalScriptRunner.ScriptSandbox do
  @moduledoc """
  Invokes a host interpreter with JSON on stdin and JSON on stdout.

  The JSON payload is written to a unique file under `System.tmp_dir/0`. A POSIX shell
  invokes `interpreter` and its arguments with `< payload-file` so the script receives a real stdin
  stream that ends at EOF without using `Port.close/1` on a combined stdio port (which
  tears down the read side and can break the child's stdout with "broken pipe" while
  dropping `{port, {:data, _}}` messages). `System.cmd/3` supervises the shell; there is
  no `Port` timeout path that calls `Port.close/1` twice. The outer `Task` and
  `Task.yield/2` enforce `timeout_milliseconds`.

  Paths are constrained to a single configurable directory tree.
  """

  @default_timeout_milliseconds 30_000

  @type execution_options :: [
          {:allowed_scripts_directory, String.t()}
          | {:timeout_milliseconds, pos_integer()}
        ]

  @doc "Ensures the candidate script path resolves inside the allowed directory without path traversal."
  @spec validate_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def validate_path(candidate_path, allowed_scripts_directory)
      when is_binary(candidate_path) and is_binary(allowed_scripts_directory) do
    if String.contains?(candidate_path, "..") do
      {:error, :path_traversal_rejected}
    else
      allowed_absolute = allowed_scripts_directory |> Path.expand() |> Path.absname()

      resolved =
        if Path.type(candidate_path) == :absolute do
          candidate_path |> Path.expand() |> Path.absname()
        else
          allowed_absolute |> Path.join(candidate_path) |> Path.expand() |> Path.absname()
        end

      if path_within_allowed_directory?(resolved, allowed_absolute) do
        {:ok, resolved}
      else
        {:error, :outside_allowed_directory}
      end
    end
  end

  @doc "Runs the resolved script with the payload as JSON on standard input and decodes JSON from standard output using directory and timeout options."
  @spec execute(String.t(), map(), execution_options()) :: {:ok, map()} | {:error, term()}
  def execute(script_path, payload_map, options \\ []) when is_map(payload_map) do
    allowed_scripts_directory =
      Keyword.get(options, :allowed_scripts_directory, Path.join(File.cwd!(), "scripts"))
      |> Path.expand()

    timeout_milliseconds =
      Keyword.get(options, :timeout_milliseconds, @default_timeout_milliseconds)

    with {:ok, resolved_script_path} <- validate_path(script_path, allowed_scripts_directory),
         {:ok, interpreter, arguments} <- interpreter_launch_configuration(resolved_script_path),
         {:ok, input_binary} <- Jason.encode(payload_map),
         {:ok, output_binary, exit_status} <-
           system_command_run_with_stdin(
             interpreter,
             arguments,
             input_binary,
             timeout_milliseconds
           ) do
      cond do
        exit_status == 0 ->
          Jason.decode(output_binary)

        true ->
          {:error, {:script_failed, exit_status, output_binary}}
      end
    end
  end

  defp path_within_allowed_directory?(resolved_path, allowed_absolute_path) do
    cond do
      resolved_path == allowed_absolute_path ->
        true

      true ->
        relative_path = Path.relative_to(resolved_path, allowed_absolute_path)
        Path.type(relative_path) == :relative
    end
  end

  defp interpreter_launch_configuration(resolved_script_path) do
    extension = Path.extname(resolved_script_path)

    cond do
      extension == ".py" ->
        case System.find_executable("python3") do
          nil -> {:error, :python3_not_found}
          interpreter_path -> {:ok, interpreter_path, [resolved_script_path]}
        end

      extension == ".sh" ->
        case System.find_executable("bash") do
          nil -> {:error, :bash_not_found}
          bash_executable -> {:ok, bash_executable, [resolved_script_path]}
        end

      true ->
        {:error, :unsupported_script_extension}
    end
  end

  defp system_command_run_with_stdin(
         executable_path,
         arguments,
         input_binary,
         timeout_milliseconds
       )
       when is_binary(executable_path) and executable_path != "" and is_list(arguments) do
    case System.find_executable("sh") do
      nil ->
        {:error, :posix_shell_not_found}

      posix_shell_path ->
        temporary_stdin_file_path =
          Path.join(
            System.tmp_dir!(),
            "local-script-runner-stdin-#{:erlang.unique_integer([:positive])}.json"
          )

        File.write!(temporary_stdin_file_path, input_binary)

        shell_command_invocation =
          ([executable_path | arguments]
           |> Enum.map(&escape_for_single_quoted_posix_shell/1)
           |> Enum.join(" ")) <>
            " < " <>
            escape_for_single_quoted_posix_shell(temporary_stdin_file_path)

        command_task =
          Task.async(fn ->
            System.cmd(posix_shell_path, ["-c", shell_command_invocation], stderr_to_stdout: true)
          end)

        try do
          case Task.yield(command_task, timeout_milliseconds) do
            {:ok, {output_binary, exit_status}} ->
              {:ok, output_binary, exit_status}

            {:exit, reason} ->
              {:error, {:command_task_failed, reason}}

            nil ->
              # Only Task.shutdown/2 tears down the shell child. There is no Port here; a prior
              # Port-based design closed the port after stdin EOF and again on timeout, which
              # double-called Port.close/1 and raised.
              Task.shutdown(command_task, :brutal_kill)
              {:error, :execution_timeout}
          end
        after
          _ = File.rm(temporary_stdin_file_path)
        end
    end
  end

  defp escape_for_single_quoted_posix_shell(segment) when is_binary(segment) do
    "'" <> String.replace(segment, "'", "'\"'\"'") <> "'"
  end
end
