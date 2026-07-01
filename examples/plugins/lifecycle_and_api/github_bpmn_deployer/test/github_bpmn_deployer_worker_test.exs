defmodule Examples.Plugins.GithubBpmnDeployer.GithubBpmnDeployerWorkerTest do
  use ExUnit.Case

  alias EvilEngine.EngineFacade
  alias Examples.Plugins.GithubBpmnDeployer.GithubBpmnDeployerWorker

  @valid_bpmn """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn:definitions
    xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
    xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
    xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
    xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
    xmlns:evil="https://evilengine.dev/schema/bpmn"
    targetNamespace="https://evilengine.dev/schema/bpmn"
    id="Definitions_1">

    <bpmn:collaboration id="Collaboration_1">
      <bpmn:participant id="Participant_1" name="Default" processRef="test-gh-process" />
    </bpmn:collaboration>

    <bpmn:process id="test-gh-process" name="Test GitHub Process" isExecutable="true">
      <bpmn:extensionElements>
        <evil:version>1.0.0</evil:version>
      </bpmn:extensionElements>

      <bpmn:laneSet id="LaneSet_1">
        <bpmn:lane id="Lane_default" name="default">
          <bpmn:flowNodeRef>Start_1</bpmn:flowNodeRef>
          <bpmn:flowNodeRef>End_1</bpmn:flowNodeRef>
        </bpmn:lane>
      </bpmn:laneSet>

      <bpmn:startEvent id="Start_1" name="Begin">
        <bpmn:outgoing>Flow_1</bpmn:outgoing>
      </bpmn:startEvent>

      <bpmn:endEvent id="End_1" name="Done">
        <bpmn:incoming>Flow_1</bpmn:incoming>
      </bpmn:endEvent>

      <bpmn:sequenceFlow id="Flow_1" sourceRef="Start_1" targetRef="End_1" />
    </bpmn:process>

    <bpmndi:BPMNDiagram id="BPMNDiagram_1">
      <bpmndi:BPMNPlane id="BPMNPlane_1" bpmnElement="Collaboration_1">
        <bpmndi:BPMNShape id="Shape_Participant_1" bpmnElement="Participant_1" isHorizontal="true">
          <dc:Bounds x="120" y="60" width="600" height="200" />
        </bpmndi:BPMNShape>
        <bpmndi:BPMNShape id="Shape_Start_1" bpmnElement="Start_1">
          <dc:Bounds x="180" y="142" width="36" height="36" />
        </bpmndi:BPMNShape>
        <bpmndi:BPMNShape id="Shape_End_1" bpmnElement="End_1">
          <dc:Bounds x="412" y="142" width="36" height="36" />
        </bpmndi:BPMNShape>
        <bpmndi:BPMNEdge id="Edge_Flow_1" bpmnElement="Flow_1">
          <di:waypoint x="216" y="160" />
          <di:waypoint x="412" y="160" />
        </bpmndi:BPMNEdge>
      </bpmndi:BPMNPlane>
    </bpmndi:BPMNDiagram>
  </bpmn:definitions>
  """

  @second_valid_bpmn """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn:definitions
    xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
    xmlns:bpmndi="http://www.omg.org/spec/BPMN/20100524/DI"
    xmlns:dc="http://www.omg.org/spec/DD/20100524/DC"
    xmlns:di="http://www.omg.org/spec/DD/20100524/DI"
    xmlns:evil="https://evilengine.dev/schema/bpmn"
    targetNamespace="https://evilengine.dev/schema/bpmn"
    id="Definitions_2">

    <bpmn:collaboration id="Collaboration_2">
      <bpmn:participant id="Participant_2" name="Default" processRef="second-process" />
    </bpmn:collaboration>

    <bpmn:process id="second-process" name="Second Process" isExecutable="true">
      <bpmn:extensionElements>
        <evil:version>2.0.0</evil:version>
      </bpmn:extensionElements>

      <bpmn:laneSet id="LaneSet_2">
        <bpmn:lane id="Lane_default_2" name="default">
          <bpmn:flowNodeRef>Start_2</bpmn:flowNodeRef>
          <bpmn:flowNodeRef>End_2</bpmn:flowNodeRef>
        </bpmn:lane>
      </bpmn:laneSet>

      <bpmn:startEvent id="Start_2" name="Begin">
        <bpmn:outgoing>Flow_2</bpmn:outgoing>
      </bpmn:startEvent>

      <bpmn:endEvent id="End_2" name="Done">
        <bpmn:incoming>Flow_2</bpmn:incoming>
      </bpmn:endEvent>

      <bpmn:sequenceFlow id="Flow_2" sourceRef="Start_2" targetRef="End_2" />
    </bpmn:process>

    <bpmndi:BPMNDiagram id="BPMNDiagram_2">
      <bpmndi:BPMNPlane id="BPMNPlane_2" bpmnElement="Collaboration_2">
        <bpmndi:BPMNShape id="Shape_Participant_2" bpmnElement="Participant_2" isHorizontal="true">
          <dc:Bounds x="120" y="60" width="600" height="200" />
        </bpmndi:BPMNShape>
        <bpmndi:BPMNShape id="Shape_Start_2" bpmnElement="Start_2">
          <dc:Bounds x="180" y="142" width="36" height="36" />
        </bpmndi:BPMNShape>
        <bpmndi:BPMNShape id="Shape_End_2" bpmnElement="End_2">
          <dc:Bounds x="412" y="142" width="36" height="36" />
        </bpmndi:BPMNShape>
        <bpmndi:BPMNEdge id="Edge_Flow_2" bpmnElement="Flow_2">
          <di:waypoint x="216" y="160" />
          <di:waypoint x="412" y="160" />
        </bpmndi:BPMNEdge>
      </bpmndi:BPMNPlane>
    </bpmndi:BPMNDiagram>
  </bpmn:definitions>
  """

  @invalid_bpmn "<not-bpmn>this is not valid XML for BPMN</not-bpmn>"

  # ---------------------------------------------------------------------------
  # Stub GitHub clients
  # ---------------------------------------------------------------------------

  defmodule StubGithubClient do
    @moduledoc false

    def build_config do
      %{
        owner: "acme-corp",
        repo: "bpmn-definitions",
        branch: "main",
        path: "processes",
        token: "ghp_test_token_stub",
        api_base_url: "https://api.github.com"
      }
    end

    def list_bpmn_files(_config) do
      {:ok,
       [
         %{
           name: "order_process.bpmn",
           download_url: "https://raw.githubusercontent.com/acme-corp/bpmn-definitions/main/processes/order_process.bpmn"
         }
       ]}
    end

    def download_raw(_url, _token) do
      {:ok, unquote(@valid_bpmn)}
    end
  end

  defmodule MultiFileGithubClient do
    @moduledoc false

    def build_config, do: StubGithubClient.build_config()

    def list_bpmn_files(_config) do
      {:ok,
       [
         %{name: "first.bpmn", download_url: "https://example.com/first.bpmn"},
         %{name: "second.bpmn", download_url: "https://example.com/second.bpmn"}
       ]}
    end

    def download_raw("https://example.com/first.bpmn", _token) do
      {:ok, unquote(@valid_bpmn)}
    end

    def download_raw("https://example.com/second.bpmn", _token) do
      {:ok, unquote(@second_valid_bpmn)}
    end
  end

  defmodule PartialDownloadFailureGithubClient do
    @moduledoc false

    def build_config, do: StubGithubClient.build_config()

    def list_bpmn_files(_config) do
      {:ok,
       [
         %{name: "good.bpmn", download_url: "https://example.com/good.bpmn"},
         %{name: "broken.bpmn", download_url: "https://example.com/broken.bpmn"}
       ]}
    end

    def download_raw("https://example.com/good.bpmn", _token) do
      {:ok, unquote(@valid_bpmn)}
    end

    def download_raw("https://example.com/broken.bpmn", _token) do
      {:error, {:http_error, 404, "Not Found"}}
    end
  end

  defmodule InvalidBpmnGithubClient do
    @moduledoc false

    def build_config, do: StubGithubClient.build_config()

    def list_bpmn_files(_config) do
      {:ok,
       [
         %{name: "valid.bpmn", download_url: "https://example.com/valid.bpmn"},
         %{name: "invalid.bpmn", download_url: "https://example.com/invalid.bpmn"}
       ]}
    end

    def download_raw("https://example.com/valid.bpmn", _token) do
      {:ok, unquote(@valid_bpmn)}
    end

    def download_raw("https://example.com/invalid.bpmn", _token) do
      {:ok, unquote(@invalid_bpmn)}
    end
  end

  defmodule EmptyRepoGithubClient do
    @moduledoc false

    def build_config, do: StubGithubClient.build_config()
    def list_bpmn_files(_config), do: {:ok, []}
  end

  defmodule FailingGithubClient do
    @moduledoc false

    def build_config, do: StubGithubClient.build_config()
    def list_bpmn_files(_config), do: {:error, {:github_api_error, "Not Found"}}
  end

  defmodule CrashingGithubClient do
    @moduledoc false

    def build_config, do: raise("simulated config explosion")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_facade(deploy_closure) do
    %EngineFacade{
      engine_id: "test-engine",
      engine_name: "test-engine",
      version: "0.0.0-test",
      processes: %EngineFacade.Processes{
        deploy: deploy_closure
      }
    }
  end

  defp run_worker_and_wait(options) do
    {:ok, worker_pid} = GithubBpmnDeployerWorker.start_link(options)
    monitor_reference = Process.monitor(worker_pid)

    receive do
      {:DOWN, ^monitor_reference, :process, ^worker_pid, reason} -> reason
    after
      5_000 -> flunk("worker did not terminate within 5 seconds")
    end
  end

  defp collect_events(events_agent) do
    Agent.get(events_agent, & &1)
  end

  defp recording_deploy_closure(events_agent) do
    fn deploy_batch ->
      Agent.update(events_agent, fn events ->
        events ++ [{:deploy, Enum.map(deploy_batch, &{&1.process_model_id, &1.version})}]
      end)

      results =
        Enum.map(deploy_batch, fn entry ->
          %{process_model_id: entry.process_model_id, version: entry.version}
        end)

      {:ok, results}
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  describe "happy path" do
    test "deploys a single BPMN file fetched from GitHub" do
      {:ok, events_agent} = Agent.start_link(fn -> [] end)
      facade = build_facade(recording_deploy_closure(events_agent))

      exit_reason =
        run_worker_and_wait(facade: facade, github_client: StubGithubClient)

      assert exit_reason == :normal
      assert [{:deploy, [{"test-gh-process", "1.0.0"}]}] = collect_events(events_agent)
    end

    test "deploys multiple BPMN files as a single batch" do
      {:ok, events_agent} = Agent.start_link(fn -> [] end)
      facade = build_facade(recording_deploy_closure(events_agent))

      exit_reason =
        run_worker_and_wait(facade: facade, github_client: MultiFileGithubClient)

      assert exit_reason == :normal

      [{:deploy, deployed_entries}] = collect_events(events_agent)
      assert length(deployed_entries) == 2
      assert {"test-gh-process", "1.0.0"} in deployed_entries
      assert {"second-process", "2.0.0"} in deployed_entries
    end
  end

  # ---------------------------------------------------------------------------
  # Empty / no-op scenarios
  # ---------------------------------------------------------------------------

  describe "empty repository" do
    test "does not call deploy when GitHub returns no files" do
      {:ok, events_agent} = Agent.start_link(fn -> [] end)

      facade =
        build_facade(fn _batch ->
          Agent.update(events_agent, fn events -> events ++ [:deploy_called] end)
          {:ok, []}
        end)

      exit_reason =
        run_worker_and_wait(facade: facade, github_client: EmptyRepoGithubClient)

      assert exit_reason == :normal
      assert collect_events(events_agent) == []
    end
  end

  # ---------------------------------------------------------------------------
  # GitHub API failure
  # ---------------------------------------------------------------------------

  describe "GitHub API failure" do
    test "terminates normally when list_bpmn_files returns an error" do
      facade = %EngineFacade{
        engine_id: "test-engine",
        engine_name: "test-engine",
        version: "0.0.0-test"
      }

      exit_reason =
        run_worker_and_wait(facade: facade, github_client: FailingGithubClient)

      assert exit_reason == :normal
    end
  end

  # ---------------------------------------------------------------------------
  # Partial download failure
  # ---------------------------------------------------------------------------

  describe "partial download failure" do
    test "deploys successfully downloaded files and skips failed downloads" do
      {:ok, events_agent} = Agent.start_link(fn -> [] end)
      facade = build_facade(recording_deploy_closure(events_agent))

      exit_reason =
        run_worker_and_wait(
          facade: facade,
          github_client: PartialDownloadFailureGithubClient
        )

      assert exit_reason == :normal

      [{:deploy, deployed_entries}] = collect_events(events_agent)
      assert [{"test-gh-process", "1.0.0"}] = deployed_entries
    end
  end

  # ---------------------------------------------------------------------------
  # BPMN parse/validation failure
  # ---------------------------------------------------------------------------

  describe "BPMN parse failure" do
    test "deploys valid files and skips files that fail parse_and_validate" do
      {:ok, events_agent} = Agent.start_link(fn -> [] end)
      facade = build_facade(recording_deploy_closure(events_agent))

      exit_reason =
        run_worker_and_wait(
          facade: facade,
          github_client: InvalidBpmnGithubClient
        )

      assert exit_reason == :normal

      [{:deploy, deployed_entries}] = collect_events(events_agent)
      assert [{"test-gh-process", "1.0.0"}] = deployed_entries
    end
  end

  # ---------------------------------------------------------------------------
  # Deploy error handling
  # ---------------------------------------------------------------------------

  describe "deploy error handling" do
    test "handles already-deployed versions idempotently" do
      {:ok, events_agent} = Agent.start_link(fn -> [] end)

      facade =
        build_facade(fn _deploy_batch ->
          Agent.update(events_agent, fn events -> events ++ [:version_exists] end)
          {:error, :version_exists, ["test-gh-process@1.0.0"]}
        end)

      exit_reason =
        run_worker_and_wait(facade: facade, github_client: StubGithubClient)

      assert exit_reason == :normal
      assert [:version_exists] = collect_events(events_agent)
    end

    test "handles generic deploy failure gracefully" do
      {:ok, events_agent} = Agent.start_link(fn -> [] end)

      facade =
        build_facade(fn _deploy_batch ->
          Agent.update(events_agent, fn events -> events ++ [:deploy_error] end)
          {:error, {:database_unavailable, "connection refused"}}
        end)

      exit_reason =
        run_worker_and_wait(facade: facade, github_client: StubGithubClient)

      assert exit_reason == :normal
      assert [:deploy_error] = collect_events(events_agent)
    end
  end

  # ---------------------------------------------------------------------------
  # Crash safety
  # ---------------------------------------------------------------------------

  describe "crash safety" do
    test "terminates normally even when the pipeline raises an exception" do
      facade = %EngineFacade{
        engine_id: "test-engine",
        engine_name: "test-engine",
        version: "0.0.0-test"
      }

      exit_reason =
        run_worker_and_wait(facade: facade, github_client: CrashingGithubClient)

      assert exit_reason == :normal
    end
  end
end
