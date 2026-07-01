defmodule EvilEngine.ExpressionsTest do
  use ExUnit.Case, async: true

  alias EvilEngine.Expressions
  alias EvilEngine.Expressions.Context
  alias EvilEngine.Expressions.Result

  # ---------------------------------------------------------------------------
  # Compile + evaluate round-trip (precompilation proof)
  # ---------------------------------------------------------------------------

  describe "compile/2 + evaluate/2" do
    test "compiles and evaluates a simple arithmetic expression" do
      {:ok, ref} = Expressions.compile("1 + 2")
      context = build_context()
      {:ok, result} = Expressions.evaluate(ref, context)
      assert result == 3
    end

    test "compiled reference can be reused with different contexts" do
      shape = %{build_scope() | "token" => %{"amount" => 0}}
      {:ok, ref} = Expressions.compile("token.amount * 2", shape)

      {:ok, r1} = Expressions.evaluate(ref, build_context(token: %{"amount" => 10}))
      {:ok, r2} = Expressions.evaluate(ref, build_context(token: %{"amount" => 500}))

      assert r1 == 20
      assert r2 == 1000
    end

    test "compiled reference evaluates against a flat string-keyed map" do
      {:ok, reference} = Expressions.compile("age + 1", %{"age" => 0})
      assert {:ok, 26} = Expressions.evaluate(reference, %{"age" => 25})
    end

    test "compiled reference evaluates against a map with atom keys" do
      {:ok, reference} = Expressions.compile("age + 1", %{"age" => 0})
      assert {:ok, 26} = Expressions.evaluate(reference, %{age: 25})
    end

    test "compile returns error for invalid syntax" do
      {:error, reason} = Expressions.compile("if then else")
      assert is_binary(reason)
      assert reason != ""
    end

    test "compile with deeply nested context shape enables deep path parsing" do
      shape = %{
        "order" => %{"customer" => %{"name" => "placeholder"}},
        "token" => %{},
        "this" => %{},
        "context" => %{},
        "dataObjects" => %{},
        "process" => %{},
        "processInstance" => %{},
        "identity" => %{}
      }

      {:ok, ref} = Expressions.compile("order.customer.name", shape)

      context = build_context()

      scope =
        Map.put(Context.to_feel_scope(context), "order", %{"customer" => %{"name" => "Eve"}})

      {:ok, result} = Expressions.Nif.eval_compiled(ref, scope)
      assert result == "Eve"
    end

    test "compile with empty expression returns error" do
      {:error, reason} = Expressions.compile("")
      assert is_binary(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # One-shot eval/2
  # ---------------------------------------------------------------------------

  describe "eval/2" do
    test "evaluates simple expression with raw map" do
      {:ok, result} = Expressions.eval("2 * 3", %{})
      assert result == 6
    end

    test "evaluates with Context struct" do
      context = build_context(token: %{"amount" => 100, "rate" => 0.15})
      {:ok, result} = Expressions.eval("token.amount * token.rate", context)
      assert_in_delta result, 15.0, 0.001
    end

    test "eval with empty string returns error" do
      {:error, reason} = Expressions.eval("", %{})
      assert is_binary(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # FEEL type coverage
  # ---------------------------------------------------------------------------

  describe "FEEL type round-trip" do
    test "boolean true" do
      assert {:ok, true} = Expressions.eval("true", %{})
    end

    test "boolean false" do
      assert {:ok, false} = Expressions.eval("false", %{})
    end

    test "null" do
      assert {:ok, nil} = Expressions.eval("null", %{})
    end

    test "string" do
      assert {:ok, "hello world"} = Expressions.eval(~S("hello world"), %{})
    end

    test "integer" do
      assert {:ok, 42} = Expressions.eval("42", %{})
    end

    test "float" do
      {:ok, result} = Expressions.eval("3.14", %{})
      assert_in_delta result, 3.14, 0.001
    end

    test "list" do
      assert {:ok, [1, 2, 3]} = Expressions.eval("[1, 2, 3]", %{})
    end

    test "context (map)" do
      {:ok, result} = Expressions.eval(~S({a: 1, b: "two"}), %{})
      assert is_map(result)
      assert result["a"] == 1
      assert result["b"] == "two"
    end

    test "date literal" do
      {:ok, result} = Expressions.eval(~S|@"2025-03-20"|, %{})
      assert {:feel_date, date_str} = result
      assert date_str =~ "2025-03-20"
    end

    test "duration literal" do
      {:ok, result} = Expressions.eval(~S|@"PT1H30M"|, %{})
      assert {:feel_duration_dt, _} = result
    end

    test "date arithmetic" do
      {:ok, result} = Expressions.eval(~S|@"2025-03-20" + @"P10D"|, %{})
      assert {:feel_date, date_str} = result
      assert date_str =~ "2025-03-30"
    end

    test "negative number" do
      assert {:ok, -42} = Expressions.eval("-42", %{})
    end

    test "empty list" do
      assert {:ok, []} = Expressions.eval("[]", %{})
    end

    test "empty context" do
      {:ok, result} = Expressions.eval("{}", %{})
      assert is_map(result)
      assert result == %{}
    end

    test "nested list" do
      {:ok, result} = Expressions.eval("[[1, 2], [3, 4]]", %{})
      assert result == [[1, 2], [3, 4]]
    end

    test "years-and-months duration" do
      {:ok, result} = Expressions.eval(~S|@"P1Y6M"|, %{})
      assert {:feel_duration_ym, _} = result
    end

    test "time literal" do
      {:ok, result} = Expressions.eval(~S|@"14:30:00"|, %{})
      assert {:feel_time, time_str} = result
      assert time_str =~ "14:30"
    end

    test "datetime literal" do
      {:ok, result} = Expressions.eval(~S|@"2025-03-20T14:30:00"|, %{})
      assert {:feel_datetime, dt_str} = result
      assert dt_str =~ "2025-03-20"
    end

    test "string-keyed context values resolve through Context struct" do
      context = build_context(token: %{"status" => "active"})
      assert {:ok, "active"} = Expressions.eval("token.status", context)
    end

    test "very large integer" do
      assert {:ok, 999_999_999} = Expressions.eval("999999999", %{})
    end
  end

  # ---------------------------------------------------------------------------
  # Engine-relevant expression patterns (from SS8.5)
  # ---------------------------------------------------------------------------

  describe "conditional sequence flow patterns" do
    test "token.amount > 100" do
      context = build_context(token: %{"amount" => 150})
      assert {:ok, true} = Expressions.eval("token.amount > 100", context)
    end

    test "token.amount > 100 returns false" do
      context = build_context(token: %{"amount" => 50})
      assert {:ok, false} = Expressions.eval("token.amount > 100", context)
    end

    test "compound boolean condition" do
      context = build_context(token: %{"status" => "approved", "amount" => 3000})
      expr = ~S(token.status = "approved" and token.amount <= 5000)
      assert {:ok, true} = Expressions.eval(expr, context)
    end
  end

  describe "path access" do
    test "simple path" do
      context = build_context(token: %{"orderId" => "ORD-123"})
      assert {:ok, "ORD-123"} = Expressions.eval("token.orderId", context)
    end

    test "deep nested path" do
      context = build_context(token: %{"order" => %{"customer" => %{"name" => "Alice"}}})
      assert {:ok, "Alice"} = Expressions.eval("token.order.customer.name", context)
    end
  end

  describe "if/then/else" do
    test "true branch" do
      context = build_context(token: %{"priority" => 8})
      expr = ~S(if token.priority > 5 then "urgent" else "normal")
      assert {:ok, "urgent"} = Expressions.eval(expr, context)
    end

    test "false branch" do
      context = build_context(token: %{"priority" => 2})
      expr = ~S(if token.priority > 5 then "urgent" else "normal")
      assert {:ok, "normal"} = Expressions.eval(expr, context)
    end
  end

  describe "list operations" do
    test "for/in/return" do
      context = build_context(token: %{"items" => [1, 2, 3]})
      assert {:ok, [2, 4, 6]} = Expressions.eval("for x in token.items return x * 2", context)
    end

    test "some/satisfies" do
      context = build_context(token: %{"scores" => [70, 85, 95]})
      assert {:ok, true} = Expressions.eval("some x in token.scores satisfies x > 90", context)
    end

    test "every/satisfies — true" do
      context = build_context(token: %{"scores" => [70, 85, 95]})
      assert {:ok, true} = Expressions.eval("every x in token.scores satisfies x > 60", context)
    end

    test "every/satisfies — false" do
      context = build_context(token: %{"scores" => [70, 85, 95]})
      assert {:ok, false} = Expressions.eval("every x in token.scores satisfies x > 80", context)
    end
  end

  describe "null propagation (FEEL three-valued logic)" do
    test "null variable evaluates to null" do
      context = build_context(token: %{"val" => nil})
      assert {:ok, nil} = Expressions.eval("token.val", context)
    end

    test "null arithmetic propagates" do
      context = build_context(token: %{"val" => nil})
      assert {:ok, nil} = Expressions.eval("token.val + 5", context)
    end
  end

  describe "built-in functions" do
    test "string length" do
      assert {:ok, 5} = Expressions.eval(~S|string length("hello")|, %{})
    end

    test "contains" do
      assert {:ok, true} = Expressions.eval(~S|contains("foobar", "bar")|, %{})
    end

    test "count" do
      assert {:ok, 4} = Expressions.eval(~S|count([1, 2, 3, 4])|, %{})
    end

    test "sum" do
      assert {:ok, 60} = Expressions.eval(~S|sum([10, 20, 30])|, %{})
    end

    test "not" do
      assert {:ok, true} = Expressions.eval(~S|not(false)|, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # Unary tests
  # ---------------------------------------------------------------------------

  describe "evaluate_unary/3" do
    test "less than — true" do
      assert {:ok, true} = Expressions.evaluate_unary("< 100", 50)
    end

    test "less than — false" do
      assert {:ok, false} = Expressions.evaluate_unary("< 100", 150)
    end

    test "range inclusive" do
      assert {:ok, true} = Expressions.evaluate_unary("[1..5]", 3)
    end

    test "range exclusive — boundary" do
      assert {:ok, false} = Expressions.evaluate_unary("(1..5)", 5)
    end

    test "greater than — true" do
      assert {:ok, true} = Expressions.evaluate_unary("> 10", 42)
    end

    test "greater than — false" do
      assert {:ok, false} = Expressions.evaluate_unary("> 10", 5)
    end

    test "equality" do
      assert {:ok, true} = Expressions.evaluate_unary("42", 42)
    end

    test "equality — mismatch" do
      assert {:ok, false} = Expressions.evaluate_unary("42", 99)
    end

    test "list membership" do
      assert {:ok, true} = Expressions.evaluate_unary("1, 3, 5", 3)
    end

    test "list membership — not in list" do
      assert {:ok, false} = Expressions.evaluate_unary("1, 3, 5", 4)
    end

    test "greater than or equal" do
      assert {:ok, true} = Expressions.evaluate_unary(">= 100", 100)
    end

    test "less than or equal" do
      assert {:ok, true} = Expressions.evaluate_unary("<= 50", 50)
    end

    test "with context variables" do
      context = %{"threshold" => 100}
      assert {:ok, true} = Expressions.evaluate_unary("> threshold", 150, context)
    end

    test "with context variables — false" do
      context = %{"threshold" => 100}
      assert {:ok, false} = Expressions.evaluate_unary("> threshold", 50, context)
    end

    test "malformed unary expression yields null (dsntk treats as no-match)" do
      {:ok, result} = Expressions.evaluate_unary("??? invalid", 50)
      assert result == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Full engine context shape (7 root bindings)
  # ---------------------------------------------------------------------------

  describe "full engine context shape" do
    test "all 7 root bindings resolve correctly" do
      context = %Context{
        token: %{"amount" => 500, "status" => "pending"},
        this: %{"id" => "Task_1", "name" => "Review Order", "type" => "userTask"},
        context: %{"department" => "sales"},
        data_objects: %{"customerName" => "Alice"},
        process: %{"id" => "OrderProcess", "name" => "Order Process", "version" => "1.0"},
        process_instance: %{"id" => "pi-001", "startedAt" => "2025-01-15T10:00:00Z"},
        identity: %{"id" => "user-42", "name" => "Bob", "roles" => ["admin", "reviewer"]}
      }

      assert {:ok, 500} = Expressions.eval("token.amount", context)
      assert {:ok, "Review Order"} = Expressions.eval("this.name", context)
      assert {:ok, "sales"} = Expressions.eval("context.department", context)
      assert {:ok, "Alice"} = Expressions.eval("dataObjects.customerName", context)
      assert {:ok, "OrderProcess"} = Expressions.eval("process.id", context)
      assert {:ok, "pi-001"} = Expressions.eval("processInstance.id", context)
      assert {:ok, "Bob"} = Expressions.eval("identity.name", context)
    end

    test "cross-binding expression works" do
      context = %Context{
        token: %{"amount" => 500},
        this: %{"type" => "userTask"},
        context: %{},
        data_objects: %{"limit" => 1000},
        process: %{},
        process_instance: %{},
        identity: %{}
      }

      assert {:ok, true} = Expressions.eval("token.amount < dataObjects.limit", context)
    end
  end

  describe "loop overlay in expression evaluation" do
    test "loop bindings are accessible in expressions" do
      context = %{build_context() | loop: %{"index" => 2, "total" => 5, "completed" => 1}}
      assert {:ok, 2} = Expressions.eval("loop.index", context)
      assert {:ok, 5} = Expressions.eval("loop.total", context)
    end
  end

  # ---------------------------------------------------------------------------
  # Context struct
  # ---------------------------------------------------------------------------

  describe "Context.flow_node_this/1" do
    test "builds string-keyed metadata map from a flow node struct" do
      flow_node = %{id: "Task_1", name: "Review Order", type: :user_task, extra: :ignored}
      result = Context.flow_node_this(flow_node)

      assert result == %{"id" => "Task_1", "name" => "Review Order", "type" => "user_task"}
    end

    test "nil name defaults to empty string" do
      flow_node = %{id: "GW_1", name: nil, type: :exclusive_gateway}
      result = Context.flow_node_this(flow_node)

      assert result["name"] == ""
    end

    test "atom type is converted to string" do
      flow_node = %{id: "ST_1", name: "Script", type: :script_task}
      result = Context.flow_node_this(flow_node)

      assert result["type"] == "script_task"
    end
  end

  describe "Context.from_handler_context/2" do
    test "converts atom-keyed process map to string-keyed FEEL map" do
      handler_context = %{
        flow_node_this: %{"id" => "Task_1", "name" => "Test", "type" => "task"},
        context: %{"tenant" => "acme"},
        data_objects: %{"DO_1" => 42},
        process: %{id: "proc-1", name: "My Process", version: "2.0"},
        process_instance: %{id: "pi-1", started_at: ~U[2025-06-01 10:00:00Z], started_by: "alice"},
        identity: %{id: "alice", roles: ["admin"], groups: ["eng"], claims: %{"org" => "acme"}}
      }

      context = Context.from_handler_context(handler_context, %{"amount" => 100})

      assert context.token == %{"amount" => 100}
      assert context.this == %{"id" => "Task_1", "name" => "Test", "type" => "task"}
      assert context.context == %{"tenant" => "acme"}

      assert context.process == %{"id" => "proc-1", "name" => "My Process", "version" => "2.0"}
      assert context.process_instance["id"] == "pi-1"
      assert context.process_instance["startedAt"] == "2025-06-01T10:00:00Z"
      assert context.process_instance["startedBy"] == "alice"

      assert context.identity == %{
               "id" => "alice",
               "roles" => ["admin"],
               "groups" => ["eng"],
               "claims" => %{"org" => "acme"}
             }
    end

    test "all bindings resolve correctly through the FEEL evaluator" do
      handler_context = %{
        flow_node_this: %{"id" => "ScriptTask_1", "name" => "Calc", "type" => "script_task"},
        context: %{"department" => "sales"},
        data_objects: %{"limit" => 500},
        process: %{id: "OrderProcess", name: "Order", version: "3.0"},
        process_instance: %{id: "pi-99", started_at: nil, started_by: "bob"},
        identity: %{id: "bob", roles: ["user"], groups: [], claims: %{}}
      }

      context = Context.from_handler_context(handler_context, %{"total" => 42})

      assert {:ok, "OrderProcess"} = Expressions.eval("process.id", context)
      assert {:ok, "Order"} = Expressions.eval("process.name", context)
      assert {:ok, "3.0"} = Expressions.eval("process.version", context)
      assert {:ok, "pi-99"} = Expressions.eval("processInstance.id", context)
      assert {:ok, "bob"} = Expressions.eval("processInstance.startedBy", context)
      assert {:ok, "bob"} = Expressions.eval("identity.id", context)
      assert {:ok, ["user"]} = Expressions.eval("identity.roles", context)
      assert {:ok, "sales"} = Expressions.eval("context.department", context)
      assert {:ok, 500} = Expressions.eval("dataObjects.limit", context)
      assert {:ok, 42} = Expressions.eval("token.total", context)
      assert {:ok, "ScriptTask_1"} = Expressions.eval("this.id", context)
    end

    test "nil token_payload defaults to empty map" do
      handler_context = %{
        flow_node_this: %{},
        context: %{},
        data_objects: %{},
        process: %{},
        process_instance: %{},
        identity: %{}
      }

      context = Context.from_handler_context(handler_context, nil)
      assert context.token == %{}
    end

    test "DateTime in started_at is converted to ISO 8601 string" do
      handler_context = %{
        flow_node_this: %{},
        context: %{},
        data_objects: %{},
        process: %{},
        process_instance: %{id: "pi-1", started_at: ~U[2025-03-15 14:30:00Z], started_by: nil},
        identity: %{}
      }

      context = Context.from_handler_context(handler_context, %{})
      assert context.process_instance["startedAt"] == "2025-03-15T14:30:00Z"
    end

    test "atom-keyed data_objects are converted to string keys" do
      handler_context = %{
        flow_node_this: %{},
        context: %{},
        data_objects: %{counter: 5},
        process: %{},
        process_instance: %{},
        identity: %{}
      }

      context = Context.from_handler_context(handler_context, %{})
      assert context.data_objects == %{"counter" => 5}
    end
  end

  describe "Context.to_feel_scope/1" do
    test "produces string-keyed map with all 7 bindings" do
      context = build_context()
      scope = Context.to_feel_scope(context)

      assert is_map(scope)
      assert Map.has_key?(scope, "token")
      assert Map.has_key?(scope, "this")
      assert Map.has_key?(scope, "context")
      assert Map.has_key?(scope, "dataObjects")
      assert Map.has_key?(scope, "process")
      assert Map.has_key?(scope, "processInstance")
      assert Map.has_key?(scope, "identity")
      refute Map.has_key?(scope, "loop")
    end

    test "includes loop overlay when present" do
      context = %{build_context() | loop: %{"index" => 0, "total" => 5}}
      scope = Context.to_feel_scope(context)
      assert scope["loop"] == %{"index" => 0, "total" => 5}
    end

    test "omits loop when nil" do
      context = build_context()
      scope = Context.to_feel_scope(context)
      refute Map.has_key?(scope, "loop")
    end
  end

  # ---------------------------------------------------------------------------
  # Result coercion helpers
  # ---------------------------------------------------------------------------

  describe "Result.to_boolean/1" do
    test "true stays true" do
      assert {:ok, true} = Result.to_boolean({:ok, true})
    end

    test "false stays false" do
      assert {:ok, false} = Result.to_boolean({:ok, false})
    end

    test "null coerces to false" do
      assert {:ok, false} = Result.to_boolean({:ok, nil})
    end

    test "error passes through" do
      assert {:error, "boom"} = Result.to_boolean({:error, "boom"})
    end

    test "non-boolean returns error with descriptive message" do
      assert {:error, msg} = Result.to_boolean({:ok, 42})
      assert is_binary(msg)
    end
  end

  describe "Result.to_string/1" do
    test "string passes through" do
      assert {:ok, "hello"} = Result.to_string({:ok, "hello"})
    end

    test "null passes through as nil" do
      assert {:ok, nil} = Result.to_string({:ok, nil})
    end

    test "non-string returns error" do
      assert {:error, msg} = Result.to_string({:ok, 42})
      assert msg =~ "expected string"
    end

    test "error passes through" do
      assert {:error, "boom"} = Result.to_string({:error, "boom"})
    end

    test "empty string passes through" do
      assert {:ok, ""} = Result.to_string({:ok, ""})
    end
  end

  describe "Result.to_list/1" do
    test "list passes through" do
      assert {:ok, [1, 2]} = Result.to_list({:ok, [1, 2]})
    end

    test "null coerces to empty list" do
      assert {:ok, []} = Result.to_list({:ok, nil})
    end

    test "non-list returns error" do
      assert {:error, msg} = Result.to_list({:ok, "nope"})
      assert msg =~ "expected list"
    end

    test "error passes through" do
      assert {:error, "boom"} = Result.to_list({:error, "boom"})
    end

    test "empty list passes through" do
      assert {:ok, []} = Result.to_list({:ok, []})
    end
  end

  describe "Result.unwrap!/1" do
    test "unwraps successful result" do
      assert 42 == Result.unwrap!({:ok, 42})
    end

    test "unwraps nil" do
      assert nil == Result.unwrap!({:ok, nil})
    end

    test "raises on error" do
      assert_raise RuntimeError, "something broke", fn ->
        Result.unwrap!({:error, "something broke"})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "invalid syntax returns {:error, ...}, never crashes" do
      assert {:error, reason} = Expressions.eval("if then else what", %{})
      assert is_binary(reason)
    end

    test "non-map context is rejected by guard clause on evaluate_unary" do
      assert_raise FunctionClauseError, fn ->
        Expressions.evaluate_unary("< 100", 50, "not_a_map")
      end
    end

    test "non-binary expression is rejected by guard clause on eval" do
      assert_raise FunctionClauseError, fn ->
        Expressions.eval(42, %{})
      end
    end

    test "non-binary expression is rejected by guard clause on compile" do
      assert_raise FunctionClauseError, fn ->
        Expressions.compile(42)
      end
    end

    test "non-map context_shape is rejected by guard clause on compile" do
      assert_raise FunctionClauseError, fn ->
        Expressions.compile("1 + 1", "not_a_map")
      end
    end

    test "accessing undefined variable returns null, not crash" do
      {:ok, result} = Expressions.eval("nonexistent", %{})
      assert result == nil
    end

    test "division by zero returns null" do
      {:ok, result} = Expressions.eval("10 / 0", %{})
      assert result == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Context struct edge cases
  # ---------------------------------------------------------------------------

  describe "Context struct construction" do
    test "requires all 7 enforce_keys" do
      assert_raise ArgumentError, fn ->
        struct!(Context, %{token: %{}})
      end
    end

    test "loop defaults to nil" do
      context = build_context()
      assert context.loop == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Precompilation performance sanity
  # ---------------------------------------------------------------------------

  describe "precompilation performance sanity" do
    test "compiled expression evaluates 1000 times without issue" do
      shape = %{build_scope() | "token" => %{"x" => 0, "y" => 0}}
      {:ok, ref} = Expressions.compile("token.x * 2 + token.y", shape)

      results =
        for i <- 1..1000 do
          context = build_context(token: %{"x" => i, "y" => i * 10})
          {:ok, r} = Expressions.evaluate(ref, context)
          r
        end

      assert length(results) == 1000
      assert Enum.at(results, 0) == 12
      assert Enum.at(results, 999) == 12_000
    end
  end

  # ---------------------------------------------------------------------------
  # User-defined FEEL functions (G20)
  # ---------------------------------------------------------------------------

  describe "user-defined FEEL functions (G20)" do
    test "function definition compiles and evaluates" do
      {:ok, reference} =
        Expressions.compile("{ myFunc: function(x, y) x + y, result: myFunc(3, 4) }.result")

      {:ok, result} = Expressions.evaluate(reference, %{})
      assert result == 7
    end

    test "function with zero parameters" do
      {:ok, reference} =
        Expressions.compile("{ constant: function() 42, result: constant() }.result")

      {:ok, result} = Expressions.evaluate(reference, %{})
      assert result == 42
    end

    test "inline function invocation" do
      {:ok, result} = Expressions.eval("(function(a, b) a * b)(6, 7)", %{})
      assert result == 42
    end
  end

  # ---------------------------------------------------------------------------
  # FEEL name qualification (G21)
  # ---------------------------------------------------------------------------

  describe "FEEL name qualification (G21)" do
    test "names with spaces resolve correctly" do
      shape = %{"Applicant Age" => 0}
      {:ok, reference} = Expressions.compile("Applicant Age > 18", shape)
      {:ok, result} = Expressions.evaluate(reference, %{"Applicant Age" => 25})
      assert result == true
    end

    test "names with spaces in context" do
      shape = %{"Credit Score" => 0, "Risk Level" => ""}

      {:ok, reference} =
        Expressions.compile(~s|if Credit Score > 700 then "low" else "high"|, shape)

      {:ok, result} = Expressions.evaluate(reference, %{"Credit Score" => 750})
      assert result == "low"
    end

    test "multiple spaced names in one expression" do
      shape = %{"Base Amount" => 0, "Tax Rate" => 0}
      {:ok, reference} = Expressions.compile("Base Amount * Tax Rate", shape)
      {:ok, result} = Expressions.evaluate(reference, %{"Base Amount" => 100, "Tax Rate" => 0.15})
      assert_in_delta result, 15.0, 0.001
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_scope do
    %{
      "token" => %{},
      "this" => %{},
      "context" => %{},
      "dataObjects" => %{},
      "process" => %{},
      "processInstance" => %{},
      "identity" => %{}
    }
  end

  defp build_context(overrides \\ []) do
    %Context{
      token: Keyword.get(overrides, :token, %{}),
      this: Keyword.get(overrides, :this, %{}),
      context: Keyword.get(overrides, :context, %{}),
      data_objects: Keyword.get(overrides, :data_objects, %{}),
      process: Keyword.get(overrides, :process, %{}),
      process_instance: Keyword.get(overrides, :process_instance, %{}),
      identity: Keyword.get(overrides, :identity, %{})
    }
  end
end
