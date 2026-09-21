defmodule BfwEngine.BPMN.SeedingRunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BfwEngine.BPMN.ModelCache
  alias BfwEngine.BPMN.SeedingRunner

  @valid_bpmn """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                    xmlns:bfw="https://bifrostforge.world/schema/bpmn" id="D1">
    <bpmn:process id="P1" isExecutable="true">
      <bpmn:extensionElements><bfw:version>1.0.0</bfw:version></bpmn:extensionElements>
      <bpmn:startEvent id="S1"/>
      <bpmn:endEvent id="E1"/>
      <bpmn:sequenceFlow id="F1" sourceRef="S1" targetRef="E1"/>
    </bpmn:process>
  </bpmn:definitions>
  """

  @invalid_bpmn """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                    xmlns:bfw="https://bifrostforge.world/schema/bpmn" id="D1">
    <bpmn:process id="P_Bad" isExecutable="true">
      <bpmn:endEvent id="E1"/>
    </bpmn:process>
  </bpmn:definitions>
  """

  setup do
    ModelCache.reset_state()
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: previous_level)
      Application.delete_env(:core_bpmn, :seeding_directory)
    end)

    :ok
  end

  describe "run/0 — valid files" do
    test "seeds processes from valid BPMN files" do
      dir = create_temp_dir()
      File.write!(Path.join(dir, "test.bpmn"), @valid_bpmn)
      Application.put_env(:core_bpmn, :seeding_directory, dir)

      log = capture_log([level: :debug], fn -> SeedingRunner.run() end)

      assert String.contains?(log, "Cached process")
      assert length(ModelCache.list_cached_ids()) == 1
    end
  end

  describe "run/0 — mixed valid and invalid" do
    test "caches valid, warns on invalid" do
      dir = create_temp_dir()
      File.write!(Path.join(dir, "good.bpmn"), @valid_bpmn)
      File.write!(Path.join(dir, "bad.bpmn"), @invalid_bpmn)
      Application.put_env(:core_bpmn, :seeding_directory, dir)

      log = capture_log([level: :debug], fn -> SeedingRunner.run() end)

      assert String.contains?(log, "Skipping bad.bpmn")
      assert length(ModelCache.list_cached_ids()) == 1
    end
  end

  describe "run/0 — unset directory" do
    test "no-op when seeding_directory is nil" do
      Application.delete_env(:core_bpmn, :seeding_directory)

      log = capture_log(fn -> SeedingRunner.run() end)
      assert log == ""
      assert ModelCache.list_cached_ids() == []
    end

    test "no-op when seeding_directory is empty string" do
      Application.put_env(:core_bpmn, :seeding_directory, "")

      log = capture_log(fn -> SeedingRunner.run() end)
      assert log == ""
      assert ModelCache.list_cached_ids() == []
    end
  end

  describe "run/0 — empty directory" do
    test "no-op with empty directory" do
      dir = create_temp_dir()
      Application.put_env(:core_bpmn, :seeding_directory, dir)

      log = capture_log([level: :debug], fn -> SeedingRunner.run() end)

      assert String.contains?(log, "Seeded 0 processes from 0 files")
    end
  end

  describe "run/0 — non-existent directory" do
    test "logs warning and continues" do
      Application.put_env(
        :core_bpmn,
        :seeding_directory,
        "/tmp/nonexistent_#{System.unique_integer()}"
      )

      log = capture_log(fn -> SeedingRunner.run() end)

      assert String.contains?(log, "does not exist")
    end
  end

  defp create_temp_dir do
    dir = Path.join(System.tmp_dir!(), "evil_seeding_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
