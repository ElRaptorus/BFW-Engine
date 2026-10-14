defmodule BfwEngine.Integration.Deployment.ProcessCatalogDeployTest do
  @moduledoc """
  Deploy-time catalog behaviour: the `enabled` sync event carries the
  deployer as its source, and concurrent first deploys of one new model
  converge on a single catalog entry.
  """
  use BfwEngine.ExecutionCase, async: false

  alias BfwEngine.Test.EventCollector
  alias BfwEngine.Types.Event

  @fixtures_directory Path.expand("../../fixtures/bpmns", __DIR__)

  defp linear_xml(version, executable) do
    @fixtures_directory
    |> Path.join("linear_start_end.bpmn")
    |> File.read!()
    |> String.replace("<bfw:version>1.0.0</bfw:version>", "<bfw:version>#{version}</bfw:version>")
    |> String.replace(~s(isExecutable="true"), ~s(isExecutable="#{executable}"))
  end

  describe "enabled sync on deploy" do
    test "publishes the deployer as source when a non-executable version disables the process",
         %{collector: collector} do
      {201, _} = http_deploy_xml(linear_xml("1.0.0", true))
      {201, _} = http_deploy_xml(linear_xml("2.0.0", false))

      disabled_events =
        collector
        |> EventCollector.await_events(2, 2_000)
        |> Enum.filter(&match?(%Event.ProcessDefinitionDisabled{}, &1))

      assert [
               %Event.ProcessDefinitionDisabled{
                 process_model_id: "LinearStartEnd",
                 source: source
               }
             ] =
               disabled_events

      assert source == "user:test-user"
    end
  end

  describe "concurrent first deploy of a new process model" do
    test "both deploys succeed and share one catalog entry" do
      results =
        ["1.0.0", "2.0.0"]
        |> Enum.map(fn version ->
          Task.async(fn -> http_deploy_xml(linear_xml(version, true)) end)
        end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({201, _}, &1))

      {200, versions} = http_list_versions("LinearStartEnd")
      assert versions |> Enum.map(& &1["version"]) |> Enum.sort() == ["1.0.0", "2.0.0"]
      assert versions |> Enum.map(& &1["processId"]) |> Enum.uniq() |> length() == 1
    end
  end
end
