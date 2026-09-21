defmodule Examples.BusinessRules.DecisionServiceSmokeTester.HealthReporterTest do
  use ExUnit.Case

  alias BfwEngine.DMN.{EvaluationTrace, ServiceEvaluationResult}
  alias Examples.BusinessRules.DecisionServiceSmokeTester.HealthReporter

  test "build/1 with all healthy results reports zero unhealthy" do
    healthy_result = %ServiceEvaluationResult{
      service_id: "PricingService",
      service_name: "Pricing Service",
      outputs: %{"Final Premium" => 450},
      trace: %EvaluationTrace{decisions: []},
      evaluated_at: DateTime.utc_now(),
      duration_microseconds: 12_400
    }

    test_results = [
      %{
        model_id: "insurance-pricing",
        service_id: "PricingService",
        outcome: {:ok, healthy_result}
      }
    ]

    report = HealthReporter.build(test_results)

    assert report.total_models == 1
    assert report.total_services == 1
    assert report.healthy == 1
    assert report.unhealthy == 0
    assert [%{status: :healthy, duration_us: 12_400}] = report.details
    assert report.details |> hd() |> Map.fetch!(:result_shape) |> Map.get(:output_count) == 1
  end

  test "build/1 with mixed healthy and unhealthy results reports correct counts" do
    healthy_result = %{
      outputs: %{"Fee" => 100},
      duration_microseconds: 5_000
    }

    test_results = [
      %{
        model_id: "insurance-pricing",
        service_id: "PricingService",
        outcome: {:ok, healthy_result}
      },
      %{
        model_id: "insurance-pricing",
        service_id: "MissingService",
        outcome: {:error, {:service_not_found, "MissingService"}}
      },
      %{
        model_id: "tax-rates",
        service_id: "TaxService",
        outcome: {:ok, %{outputs: %{}, duration_microseconds: 1_000}}
      }
    ]

    report = HealthReporter.build(test_results)

    assert report.total_models == 2
    assert report.total_services == 3
    assert report.healthy == 2
    assert report.unhealthy == 1

    unhealthy_detail =
      Enum.find(report.details, &(&1.service_id == "MissingService"))

    assert unhealthy_detail.status == :unhealthy
    assert unhealthy_detail.error == {:service_not_found, "MissingService"}
  end

  test "build/1 with empty results produces zeroed summary" do
    report = HealthReporter.build([])

    assert report.total_models == 0
    assert report.total_services == 0
    assert report.healthy == 0
    assert report.unhealthy == 0
    assert report.details == []
    assert %DateTime{} = report.timestamp
  end
end
