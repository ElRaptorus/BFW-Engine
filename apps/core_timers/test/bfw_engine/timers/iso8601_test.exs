defmodule BfwEngine.Timers.ISO8601Test do
  use ExUnit.Case, async: true

  alias BfwEngine.Timers.ISO8601

  @reference_time ~U[2026-06-01 10:00:00Z]

  # -------------------------------------------------------------------------
  # resolve_fire_at/3 — :date
  # -------------------------------------------------------------------------

  describe "resolve_fire_at(:date, ...)" do
    test "parses a valid UTC datetime" do
      assert {:ok, ~U[2026-12-25 08:00:00Z]} =
               ISO8601.resolve_fire_at(:date, "2026-12-25T08:00:00Z", @reference_time)
    end

    test "parses a datetime with offset" do
      {:ok, result} = ISO8601.resolve_fire_at(:date, "2026-06-01T12:00:00+02:00", @reference_time)
      assert result == ~U[2026-06-01 10:00:00Z]
    end

    test "returns error for invalid date string" do
      assert {:error, {:invalid_date, _reason}} =
               ISO8601.resolve_fire_at(:date, "not-a-date", @reference_time)
    end

    test "returns error for empty string" do
      assert {:error, {:invalid_date, _reason}} =
               ISO8601.resolve_fire_at(:date, "", @reference_time)
    end

    test "ignores reference_time entirely" do
      {:ok, result1} =
        ISO8601.resolve_fire_at(:date, "2026-06-15T09:00:00Z", ~U[2020-01-01 00:00:00Z])

      {:ok, result2} =
        ISO8601.resolve_fire_at(:date, "2026-06-15T09:00:00Z", ~U[2030-12-31 23:59:59Z])

      assert result1 == result2
    end
  end

  # -------------------------------------------------------------------------
  # resolve_fire_at/3 — :duration
  # -------------------------------------------------------------------------

  describe "resolve_fire_at(:duration, ...)" do
    test "parses PT1H (one hour)" do
      {:ok, result} = ISO8601.resolve_fire_at(:duration, "PT1H", @reference_time)
      assert result == ~U[2026-06-01 11:00:00Z]
    end

    test "parses PT30M (thirty minutes)" do
      {:ok, result} = ISO8601.resolve_fire_at(:duration, "PT30M", @reference_time)
      assert result == ~U[2026-06-01 10:30:00Z]
    end

    test "parses PT5S (five seconds)" do
      {:ok, result} = ISO8601.resolve_fire_at(:duration, "PT5S", @reference_time)
      assert result == ~U[2026-06-01 10:00:05Z]
    end

    test "parses P1D (one day)" do
      {:ok, result} = ISO8601.resolve_fire_at(:duration, "P1D", @reference_time)
      assert result == ~U[2026-06-02 10:00:00Z]
    end

    test "parses P1DT2H30M (complex duration)" do
      {:ok, result} = ISO8601.resolve_fire_at(:duration, "P1DT2H30M", @reference_time)
      assert result == ~U[2026-06-02 12:30:00Z]
    end

    test "parses P7D (one week)" do
      {:ok, result} = ISO8601.resolve_fire_at(:duration, "P7D", @reference_time)
      assert result == ~U[2026-06-08 10:00:00Z]
    end

    test "parses PT1H30M (combined hour and minute duration)" do
      {:ok, result} = ISO8601.resolve_fire_at(:duration, "PT1H30M", @reference_time)
      assert result == ~U[2026-06-01 11:30:00Z]
    end

    test "returns error for invalid duration string" do
      assert {:error, {:invalid_duration, _reason}} =
               ISO8601.resolve_fire_at(:duration, "not-a-duration", @reference_time)
    end

    test "returns error for empty string" do
      assert {:error, {:invalid_duration, _reason}} =
               ISO8601.resolve_fire_at(:duration, "", @reference_time)
    end

    test "result is relative to reference_time" do
      {:ok, result1} = ISO8601.resolve_fire_at(:duration, "PT1H", ~U[2026-01-01 00:00:00Z])
      {:ok, result2} = ISO8601.resolve_fire_at(:duration, "PT1H", ~U[2026-06-15 12:00:00Z])

      assert result1 == ~U[2026-01-01 01:00:00Z]
      assert result2 == ~U[2026-06-15 13:00:00Z]
    end
  end

  # -------------------------------------------------------------------------
  # resolve_fire_at/3 — :cycle
  # -------------------------------------------------------------------------

  describe "resolve_fire_at(:cycle, ...)" do
    test "parses R3/PT1H (finite cycle, no start)" do
      {:ok, {:cycle, cycle_spec}} = ISO8601.resolve_fire_at(:cycle, "R3/PT1H", @reference_time)

      assert cycle_spec.repetitions == 3
      assert cycle_spec.start_at == nil
      assert %Duration{} = cycle_spec.interval_duration
    end

    test "parses R/PT30M (infinite cycle, no start)" do
      {:ok, {:cycle, cycle_spec}} = ISO8601.resolve_fire_at(:cycle, "R/PT30M", @reference_time)

      assert cycle_spec.repetitions == :infinite
      assert cycle_spec.start_at == nil
    end

    test "parses R5/2026-06-01T10:00:00Z/PT1H (finite cycle with start)" do
      {:ok, {:cycle, cycle_spec}} =
        ISO8601.resolve_fire_at(:cycle, "R5/2026-06-01T10:00:00Z/PT1H", @reference_time)

      assert cycle_spec.repetitions == 5
      assert cycle_spec.start_at == ~U[2026-06-01 10:00:00Z]
    end

    test "parses R/2026-06-01T10:00:00Z/P1D (infinite cycle with start)" do
      {:ok, {:cycle, cycle_spec}} =
        ISO8601.resolve_fire_at(:cycle, "R/2026-06-01T10:00:00Z/P1D", @reference_time)

      assert cycle_spec.repetitions == :infinite
      assert cycle_spec.start_at == ~U[2026-06-01 10:00:00Z]
    end

    test "returns error for malformed cycle string" do
      assert {:error, _reason} = ISO8601.resolve_fire_at(:cycle, "R3", @reference_time)
    end

    test "returns error for cycle with invalid repetition count" do
      assert {:error, _reason} = ISO8601.resolve_fire_at(:cycle, "R0/PT1H", @reference_time)
    end

    test "returns error for cycle with negative repetition count" do
      assert {:error, _reason} = ISO8601.resolve_fire_at(:cycle, "R-1/PT1H", @reference_time)
    end

    test "returns error for cycle with invalid duration" do
      assert {:error, _reason} =
               ISO8601.resolve_fire_at(:cycle, "R3/not-a-duration", @reference_time)
    end

    test "returns error for cycle with invalid start datetime" do
      assert {:error, _reason} =
               ISO8601.resolve_fire_at(:cycle, "R3/invalid-datetime/PT1H", @reference_time)
    end

    test "returns error for too many slashes" do
      assert {:error, _reason} =
               ISO8601.resolve_fire_at(
                 :cycle,
                 "R3/2026-06-01T10:00:00Z/PT1H/extra",
                 @reference_time
               )
    end
  end

  # -------------------------------------------------------------------------
  # parse_cycle/1
  # -------------------------------------------------------------------------

  describe "parse_cycle/1" do
    test "parses R3/PT10S (finite repetitions with second interval)" do
      assert {:ok, %{repetitions: 3, start_at: nil}} = ISO8601.parse_cycle("R3/PT10S")
    end

    test "two-part format: R<n>/P..." do
      assert {:ok, %{repetitions: 10, start_at: nil}} = ISO8601.parse_cycle("R10/PT10S")
    end

    test "two-part format: R/P... (infinite)" do
      assert {:ok, %{repetitions: :infinite, start_at: nil}} = ISO8601.parse_cycle("R/PT1H")
    end

    test "three-part format with start datetime" do
      assert {:ok, %{repetitions: 2, start_at: ~U[2026-01-01 00:00:00Z]}} =
               ISO8601.parse_cycle("R2/2026-01-01T00:00:00Z/P1D")
    end

    test "rejects non-R prefix" do
      assert {:error, _reason} = ISO8601.parse_cycle("X3/PT1H")
    end

    test "rejects R with non-numeric suffix" do
      assert {:error, _reason} = ISO8601.parse_cycle("Rabc/PT1H")
    end

    test "rejects single-segment string" do
      assert {:error, {:invalid_cycle_format, _}} = ISO8601.parse_cycle("R3")
    end
  end

  # -------------------------------------------------------------------------
  # next_cycle_fire/2
  # -------------------------------------------------------------------------

  describe "next_cycle_fire/2" do
    test "infinite cycle always returns next fire time" do
      cycle_spec = %{
        repetitions: :infinite,
        interval_duration: Duration.new!(hour: 1),
        start_at: nil
      }

      last_fire = ~U[2026-06-01 10:00:00Z]

      {next_fire, updated_spec} = ISO8601.next_cycle_fire(cycle_spec, last_fire)

      assert next_fire == ~U[2026-06-01 11:00:00Z]
      assert updated_spec.repetitions == :infinite
    end

    test "finite cycle with remaining > 1 returns next fire and decrements" do
      cycle_spec = %{repetitions: 3, interval_duration: Duration.new!(minute: 30), start_at: nil}
      last_fire = ~U[2026-06-01 10:00:00Z]

      {next_fire, updated_spec} = ISO8601.next_cycle_fire(cycle_spec, last_fire)

      assert next_fire == ~U[2026-06-01 10:30:00Z]
      assert updated_spec.repetitions == 2
    end

    test "finite cycle with remaining == 1 returns nil (exhausted)" do
      cycle_spec = %{repetitions: 1, interval_duration: Duration.new!(minute: 30), start_at: nil}
      last_fire = ~U[2026-06-01 10:00:00Z]

      assert nil == ISO8601.next_cycle_fire(cycle_spec, last_fire)
    end

    test "finite cycle counts down through multiple fires" do
      cycle_spec = %{repetitions: 3, interval_duration: Duration.new!(second: 10), start_at: nil}
      last_fire = ~U[2026-06-01 10:00:00Z]

      {fire_1, spec_1} = ISO8601.next_cycle_fire(cycle_spec, last_fire)
      assert fire_1 == ~U[2026-06-01 10:00:10Z]
      assert spec_1.repetitions == 2

      {fire_2, spec_2} = ISO8601.next_cycle_fire(spec_1, fire_1)
      assert fire_2 == ~U[2026-06-01 10:00:20Z]
      assert spec_2.repetitions == 1

      assert nil == ISO8601.next_cycle_fire(spec_2, fire_2)
    end
  end

  # -------------------------------------------------------------------------
  # first_fire_at/2
  # -------------------------------------------------------------------------

  describe "first_fire_at/2" do
    test "without start_at: fires relative to reference_time" do
      cycle_spec = %{repetitions: 5, interval_duration: Duration.new!(hour: 2), start_at: nil}
      reference = ~U[2026-06-01 08:00:00Z]

      assert ISO8601.first_fire_at(cycle_spec, reference) == ~U[2026-06-01 10:00:00Z]
    end

    test "with start_at: fires relative to start_at, ignoring reference_time" do
      cycle_spec = %{
        repetitions: 5,
        interval_duration: Duration.new!(hour: 1),
        start_at: ~U[2026-06-01 12:00:00Z]
      }

      reference = ~U[2026-01-01 00:00:00Z]

      assert ISO8601.first_fire_at(cycle_spec, reference) == ~U[2026-06-01 13:00:00Z]
    end
  end
end
