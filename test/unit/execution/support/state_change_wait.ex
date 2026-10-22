defmodule BfwEngine.Execution.TestSupport.StateChangeWait do
  @moduledoc """
  Wait for Process Instance and Flow Node Instance state changes through
  telemetry instead of monitoring the Process Instance pid.

  A Process Instance that finishes immediately (past timer, `PT0S`) can exit
  before the test calls `Process.monitor/1`. The monitor then reports
  `:noproc` instead of the exit reason. Attach **before** starting the
  Process Instance; the handler's messages stay in the test mailbox until
  they are awaited, however fast the instance finishes.
  """

  import ExUnit.Assertions

  @default_timeout_ms 5_000

  @doc """
  Attaches handlers for Process Instance and Flow Node Instance state
  changes. Returns the reference to pass to the `assert_*` functions.
  Call it from the test process; the handlers detach on test exit.
  """
  @spec attach() :: reference()
  def attach do
    reference = make_ref()
    test_process = self()
    handler_id = "state-change-wait-#{inspect(reference)}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:bfw_engine, :process_instance, :state_change],
          [:bfw_engine, :flow_node_instance, :state_change]
        ],
        &__MODULE__.forward/4,
        {test_process, reference}
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)
    reference
  end

  @doc false
  def forward(
        [:bfw_engine, :process_instance, :state_change],
        _measurements,
        metadata,
        {test_process, reference}
      ) do
    send(test_process, {:process_instance_state_changed, reference, metadata})
  end

  def forward(
        [:bfw_engine, :flow_node_instance, :state_change],
        _measurements,
        metadata,
        {test_process, reference}
      ) do
    send(test_process, {:flow_node_instance_state_changed, reference, metadata})
  end

  @spec assert_process_instance_state(reference(), String.t(), atom(), pos_integer()) :: map()
  def assert_process_instance_state(
        reference,
        process_instance_id,
        expected_state,
        timeout \\ @default_timeout_ms
      ) do
    receive do
      {:process_instance_state_changed, ^reference,
       %{process_instance_id: ^process_instance_id, new_state: ^expected_state} = metadata} ->
        metadata
    after
      timeout ->
        flunk(
          "Process Instance #{process_instance_id} did not reach state #{inspect(expected_state)} within #{timeout}ms"
        )
    end
  end

  @spec assert_flow_node_instance_terminal_state(reference(), String.t(), atom(), pos_integer()) ::
          map()
  def assert_flow_node_instance_terminal_state(
        reference,
        flow_node_instance_id,
        expected_state,
        timeout \\ @default_timeout_ms
      ) do
    receive do
      {:flow_node_instance_state_changed, ^reference,
       %{flow_node_instance_id: ^flow_node_instance_id, terminal_state: ^expected_state} =
           metadata} ->
        metadata
    after
      timeout ->
        flunk(
          "Flow Node Instance #{flow_node_instance_id} did not reach terminal state #{inspect(expected_state)} within #{timeout}ms"
        )
    end
  end
end
