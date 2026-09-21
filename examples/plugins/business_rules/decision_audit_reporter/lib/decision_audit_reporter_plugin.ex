defmodule Examples.BusinessRules.DecisionAuditReporter.DecisionAuditReporterPlugin do
  @moduledoc """
  Lifecycle plugin that observes DMN Business Rule Task completions, inspects
  persisted flow node instances, runs boundary evaluations, and logs a
  compliance audit report after a collection window.
  """

  @behaviour BfwEngine.Plugin

  alias Examples.BusinessRules.DecisionAuditReporter.AuditReporterWorker
  alias Examples.BusinessRules.DecisionAuditReporter.AuditSink
  alias Examples.BusinessRules.DecisionAuditReporter.FacadeStore

  @doc "Persists the engine facade and registers the audit event sink."
  @impl true
  def on_load(engine_facade) do
    :ok = FacadeStore.put(engine_facade)
    engine_facade.register_event_sink.("decision_audit_reporter", AuditSink, [])
    :ok
  end

  @doc "Starts the audit reporter worker using the facade stored during on_load/1."
  @impl true
  def on_ready(_engine_facade) do
    case FacadeStore.get() do
      nil ->
        {:error, :facade_missing_from_store}

      stored_facade ->
        case AuditReporterWorker.start_link(facade: stored_facade) do
          {:ok, _worker_pid} -> :ok
          {:error, reason} -> {:error, {:worker_start_failed, reason}}
        end
    end
  end
end
