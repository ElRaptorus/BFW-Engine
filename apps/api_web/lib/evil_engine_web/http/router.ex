defmodule EvilEngineWeb.Http.Router do
  @moduledoc """
  HTTP router. Public routes (`/health`, `/info`, `/metrics`) bypass auth;
  everything else passes through the JWT auth pipeline.
  Swagger UI is served at `GET /`, OpenAPI spec at `GET /api/openapi`.
  """

  use Phoenix.Router

  import Plug.Conn

  pipeline :api do
    plug :accepts, ["json"]
    plug EvilEngineWeb.Http.Plugs.SecurityHeadersPlug
  end

  pipeline :authenticated do
    plug :accepts, ["json"]
    plug EvilEngineWeb.Http.Plugs.SecurityHeadersPlug
    plug EvilEngine.Auth.Plug
    plug EvilEngineWeb.Http.Plugs.AshActorPlug
    plug EvilEngineWeb.Http.Plugs.PayloadCapPlug, field: "payload"
    plug EvilEngineWeb.Http.Plugs.RateLimitPlug
    plug EvilEngineWeb.Http.Plugs.DeprecationPlug
  end

  pipeline :graphql_context do
    plug EvilEngineWeb.Http.Plugs.AbsintheContext
  end

  pipeline :swagger_ui do
    plug :accepts, ["html"]

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; " <>
          "script-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; " <>
          "style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; " <>
          "img-src 'self' data:; " <>
          "font-src 'self' https://cdn.jsdelivr.net"
    }
  end

  pipeline :devtools do
    plug EvilEngineWeb.Http.Plugs.DevtoolsGatePlug
  end

  pipeline :openapi_gate do
    plug EvilEngineWeb.Http.Plugs.DevtoolsGatePlug, allow_if: :expose_openapi_spec
  end

  scope "/", EvilEngineWeb.Http do
    pipe_through :api

    get "/health", HealthController, :index
    get "/info", InfoController, :index
    get "/metrics", MetricsController, :index
  end

  scope "/", EvilEngineWeb.Http do
    pipe_through :authenticated

    get "/stats", StatsController, :index

    get "/processes", ProcessController, :index
    get "/processes/:model_id", ProcessController, :show
    get "/processes/:model_id/versions", ProcessController, :versions
    post "/processes", ProcessController, :deploy
    post "/processes/:model_id/start", ProcessController, :start
    put "/processes/:model_id/enable", ProcessController, :enable
    put "/processes/:model_id/disable", ProcessController, :disable
    delete "/processes/:model_id", ProcessController, :undeploy
    delete "/processes/:model_id/versions/:version", ProcessController, :delete_version

    # DMN decision endpoints
    get "/decisions", DecisionController, :index
    get "/decisions/:model_id", DecisionController, :show
    get "/decisions/:model_id/versions", DecisionController, :versions
    post "/decisions", DecisionController, :deploy
    post "/decisions/:model_id/evaluate", DecisionController, :evaluate
    post "/decisions/:model_id/versions/:version/evaluate", DecisionController, :evaluate_version

    post "/decisions/:model_id/services/:service_id/evaluate",
         DecisionController,
         :evaluate_service

    put "/decisions/:model_id/enable", DecisionController, :enable
    put "/decisions/:model_id/disable", DecisionController, :disable
    delete "/decisions/:model_id", DecisionController, :undeploy
    delete "/decisions/:model_id/versions/:version", DecisionController, :delete_version

    put "/user-tasks/:flow_node_instance_id/finish", UserTaskController, :finish
    put "/user-tasks/:flow_node_instance_id/cancel", UserTaskController, :cancel
    put "/process-instances/:id/abort", ProcessInstanceController, :abort
    put "/process-instances/:id/retry", ProcessInstanceController, :retry
    delete "/process-instances/:id", ProcessInstanceController, :soft_delete

    get "/timer-schedules", TimerScheduleController, :index
    get "/timer-schedules/:id", TimerScheduleController, :show
    put "/timer-schedules/:id/enable", TimerScheduleController, :enable
    put "/timer-schedules/:id/disable", TimerScheduleController, :disable

    post "/timer-events/:flow_node_instance_id/trigger", TimerEventController, :trigger

    post "/messages/:message_name/trigger", MessageController, :publish
    post "/signals/:signal_name/trigger", SignalController, :publish

    get "/adhoc-subprocesses/:id/activities", AdhocSubprocessController, :list_activities

    post "/adhoc-subprocesses/:id/activities/:activity_id/activate",
         AdhocSubprocessController,
         :activate_activity

    post "/adhoc-subprocesses/:id/complete", AdhocSubprocessController, :complete
    get "/adhoc-subprocesses/:id/status", AdhocSubprocessController, :status
  end

  scope "/api" do
    pipe_through [:api, :openapi_gate]

    get "/openapi", EvilEngineWeb.Http.OpenApiController, :spec
  end

  scope "/api/v1" do
    pipe_through [:authenticated, :graphql_context]

    forward "/graphql", Absinthe.Plug,
      schema: EvilEngineWeb.Graphql.Schema,
      analyze_complexity: true,
      max_complexity: Application.compile_env(:api_web, :graphql_max_complexity, 1000),
      pipeline: {EvilEngineWeb.Graphql.PipelineModifier, :pipeline}
  end

  scope "/admin", EvilEngineWeb.Http do
    pipe_through [:swagger_ui, :devtools]

    get "/graphiql", PlaygroundController, :index
  end

  scope "/" do
    pipe_through [:swagger_ui, :devtools]

    get "/", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/openapi",
      operations_sorter: """
      function(a, b) {
        var order = {get: 0, post: 1, put: 2, patch: 3, delete: 4};
        var ma = a.get("method") in order ? order[a.get("method")] : 99;
        var mb = b.get("method") in order ? order[b.get("method")] : 99;
        if (ma !== mb) return ma - mb;
        var pa = a.get("path");
        var pb = b.get("path");
        return pa < pb ? -1 : pa > pb ? 1 : 0;
      }
      """
  end

  # Last: plugin REST extensions. Specific engine, OpenAPI, GraphQL, and
  # Swagger routes above win first. Unknown paths 404 without auth; a
  # matching plugin prefix then requires JWT (engine claims are not applied).
  scope "/", EvilEngineWeb.Http do
    pipe_through :api

    match :*, "/*path", PluginExtensionController, :dispatch
  end
end
