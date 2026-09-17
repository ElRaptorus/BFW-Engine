defmodule EvilEngineWeb.Http.PlaygroundController do
  @moduledoc """
  Serves GraphQL Playground with pre-populated example query tabs.

  Replaces the default blank `Absinthe.Plug.GraphiQL` page with a
  custom HTML page that loads GraphQL Playground from CDN and configures
  it with named tabs covering the query surface including the BPMN process-model graph.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  @graphql_endpoint "/api/v1/graphql"

  @tabs Jason.encode!([
          %{
            endpoint: @graphql_endpoint,
            name: "List Processes",
            query: """
            {
              processes {
                results {
                  id
                  processModelId
                  name
                  enabled
                  createdAt
                }
              }
            }
            """
          },
          %{
            endpoint: @graphql_endpoint,
            name: "Get Process by ID",
            query: """
            query GetProcess($id: ID!) {
              getProcess(id: $id) {
                id
                processModelId
                name
                enabled
                createdAt
              }
            }
            """,
            variables: ~s({"id": "replace-with-uuid"})
          },
          %{
            endpoint: @graphql_endpoint,
            name: "List Process Versions",
            query: """
            {
              processVersions {
                results {
                  id
                  version
                  processId
                  deployedAt
                }
              }
            }
            """
          },
          %{
            endpoint: @graphql_endpoint,
            name: "Get Process Version",
            query: """
            query GetProcessVersion($id: ID!) {
              getProcessVersion(id: $id) {
                id
                version
                processId
                deployedAt
                processModel {
                  id
                  name
                  correlationKey
                }
              }
            }
            """,
            variables: ~s({"id": "replace-with-uuid"})
          },
          %{
            endpoint: @graphql_endpoint,
            name: "List Process Instances",
            query: """
            {
              processInstances {
                results {
                  id
                  state
                  startedAt
                  finishedAt
                  processVersionId
                  businessKey
                }
              }
            }
            """
          },
          %{
            endpoint: @graphql_endpoint,
            name: "Get Process Instance",
            query: """
            query GetProcessInstance($id: ID!) {
              getProcessInstance(id: $id) {
                id
                state
                processVersionId
                businessKey
                startedAt
                finishedAt
                startedBy
                finalTokens
              }
            }
            """,
            variables: ~s({"id": "replace-with-uuid"})
          },
          %{
            endpoint: @graphql_endpoint,
            name: "Process Model Graph",
            query: """
            query DebuggerView($id: ID!) {
              getProcessInstance(id: $id) {
                id
                state
                processVersion {
                  id
                  bpmnXml
                  processModel {
                    id
                    name
                    correlationKey
                  }
                }
                flowNodeInstances {
                  id
                  state
                  flowNode {
                    id
                    name
                    type
                    ... on UserTaskNode {
                      formSchema
                      resultContract
                    }
                    ... on ServiceTaskNode {
                      implementation
                      httpUrl
                      httpMethod
                    }
                    ... on CallActivityNode {
                      calledElement
                    }
                  }
                }
              }
            }
            """,
            variables: ~s({"id": "replace-with-uuid"})
          },
          %{
            endpoint: @graphql_endpoint,
            name: "List Flow Node Instances",
            query: """
            {
              flowNodeInstances {
                results {
                  id
                  flowNodeId
                  flowNodeType
                  state
                  laneName
                  processInstanceId
                  inputToken
                  outputToken
                }
              }
            }
            """
          },
          %{
            endpoint: @graphql_endpoint,
            name: "Get Flow Node Instance",
            query: """
            query GetFlowNodeInstance($id: ID!) {
              getFlowNodeInstance(id: $id) {
                id
                flowNodeId
                flowNodeType
                state
                laneName
                processInstanceId
              }
            }
            """,
            variables: ~s({"id": "replace-with-uuid"})
          },
          %{
            endpoint: @graphql_endpoint,
            name: "List Data Object Values",
            query: """
            query ListDataObjectValues($processInstanceId: ID!) {
              dataObjectValues(filter: {processInstanceId: {eq: $processInstanceId}}) {
                results {
                  id
                  dataObjectId
                  processInstanceId
                  value
                }
              }
            }
            """,
            variables: ~s({"processInstanceId": "replace-with-uuid"})
          },
          %{
            endpoint: @graphql_endpoint,
            name: "Get Data Object Value",
            query: """
            query GetDataObjectValue($id: ID!) {
              getDataObjectValue(id: $id) {
                id
                dataObjectId
                processInstanceId
                value
              }
            }
            """,
            variables: ~s({"id": "replace-with-uuid"})
          },
          %{
            endpoint: @graphql_endpoint,
            name: "List Data Object History",
            query: """
            query ListDataObjectHistory($processInstanceId: ID!) {
              dataObjectHistory(filter: {processInstanceId: {eq: $processInstanceId}}) {
                results {
                  id
                  dataObjectId
                  processInstanceId
                  value
                  createdAt
                }
              }
            }
            """,
            variables: ~s({"processInstanceId": "replace-with-uuid"})
          },
          %{
            endpoint: @graphql_endpoint,
            name: "List Decision Definitions",
            query: """
            {
              decisionDefinitions {
                results {
                  id
                  decisionDefinitionId
                  name
                  enabled
                }
              }
            }
            """
          },
          %{
            endpoint: @graphql_endpoint,
            name: "Get Decision Definition",
            query: """
            query GetDecisionDefinition($id: ID!) {
              getDecisionDefinition(id: $id) {
                id
                decisionDefinitionId
                name
                enabled
              }
            }
            """,
            variables: ~s({"id": "replace-with-uuid"})
          },
          %{
            endpoint: @graphql_endpoint,
            name: "List Decision Versions",
            query: """
            {
              decisionVersions {
                results {
                  id
                  version
                  decisionDefinitionId
                  deployedAt
                }
              }
            }
            """
          },
          %{
            endpoint: @graphql_endpoint,
            name: "Get Decision Version",
            query: """
            query GetDecisionVersion($id: ID!) {
              getDecisionVersion(id: $id) {
                id
                version
                decisionDefinitionId
                deployedAt
              }
            }
            """,
            variables: ~s({"id": "replace-with-uuid"})
          },
          %{
            endpoint: @graphql_endpoint,
            name: "Schema Introspection",
            query: """
            {
              __schema {
                queryType {
                  fields {
                    name
                    description
                    args {
                      name
                      type {
                        name
                        kind
                      }
                    }
                  }
                }
              }
            }
            """
          }
        ])

  @html """
  <!DOCTYPE html>
  <html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>GraphQL Playground — Daemon Engine</title>
    <link rel="stylesheet"
          href="https://cdn.jsdelivr.net/npm/graphql-playground-react/build/static/css/index.css" />
    <script src="https://cdn.jsdelivr.net/npm/graphql-playground-react/build/static/js/middleware.js"></script>
    <style>
      body { margin: 0; overflow: hidden; }
      #auth-bar {
        display: flex; align-items: center; gap: 8px;
        height: 40px; padding: 0 12px;
        background: #0b1924; border-bottom: 1px solid #1a2a3a;
        font-family: 'Open Sans', sans-serif; font-size: 13px; color: #a0aab4;
      }
      #auth-bar label { white-space: nowrap; }
      #auth-bar input {
        flex: 1; padding: 4px 8px;
        background: #122333; border: 1px solid #1a2a3a; border-radius: 3px;
        color: #d4dae0; font-family: monospace; font-size: 12px;
      }
      #auth-bar input::placeholder { color: #5a6a7a; }
      #auth-bar button {
        padding: 4px 14px;
        background: #1a8c5b; border: none; border-radius: 3px;
        color: #fff; font-size: 12px; font-weight: 600; cursor: pointer;
      }
      #auth-bar button:hover { background: #1da06a; }
      #auth-bar .hint { font-size: 11px; color: #5a6a7a; }
      #root { height: calc(100vh - 41px); }
    </style>
  </head>
  <body>
    <div id="auth-bar">
      <label>Bearer Token:</label>
      <input id="token-input" type="text"
             placeholder="paste token from: mix evil.mint_token" />
      <button onclick="applyToken()">Apply</button>
      <span class="hint">Token persists in localStorage</span>
    </div>
    <div id="root"></div>
    <script>
      var TABS = #{@tabs};
      var ENDPOINT = "#{@graphql_endpoint}";
      var STORAGE_KEY = "evil_playground_token";

      function applyToken() {
        var token = document.getElementById("token-input").value.trim();
        if (token) {
          localStorage.setItem(STORAGE_KEY, token);
        } else {
          localStorage.removeItem(STORAGE_KEY);
        }
        location.reload();
      }

      (function() {
        var saved = localStorage.getItem(STORAGE_KEY);
        if (saved) {
          var _fetch = window.fetch;
          window.fetch = function(url, opts) {
            if (typeof url === "string" && url.indexOf(ENDPOINT) !== -1) {
              opts = opts || {};
              if (!opts.headers) { opts.headers = {}; }
              if (opts.headers instanceof Headers) {
                opts.headers.set("Authorization", "Bearer " + saved);
              } else {
                opts.headers["Authorization"] = "Bearer " + saved;
              }
            }
            return _fetch.call(window, url, opts);
          };
        }
      })();

      window.addEventListener("load", function() {
        var saved = localStorage.getItem(STORAGE_KEY);
        if (saved) { document.getElementById("token-input").value = saved; }
        GraphQLPlayground.init(document.getElementById("root"), {
          endpoint: ENDPOINT,
          tabs: TABS,
          settings: { "schema.polling.enable": false }
        });
      });
    </script>
  </body>
  </html>
  """

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, @html)
  end
end
