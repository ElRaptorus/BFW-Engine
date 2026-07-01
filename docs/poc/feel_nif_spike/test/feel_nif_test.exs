defmodule FeelNifTest do
  use ExUnit.Case

  # ---------------------------------------------------------------------------
  # 1. Basic compilation and evaluation
  # ---------------------------------------------------------------------------

  describe "compile + eval_compiled round-trip" do
    test "compiles and evaluates a simple arithmetic expression" do
      {:ok, ref} = FeelNif.compile("1 + 2", %{})
      {:ok, result} = FeelNif.eval_compiled(ref, %{})
      assert result == 3
    end

    test "compiled reference can be reused with different contexts" do
      ctx = %{"x" => 0, "y" => 0}
      {:ok, ref} = FeelNif.compile("x + y", ctx)
      {:ok, r1} = FeelNif.eval_compiled(ref, %{"x" => 10, "y" => 20})
      {:ok, r2} = FeelNif.eval_compiled(ref, %{"x" => 100, "y" => 200})
      assert r1 == 30
      assert r2 == 300
    end

    test "compile returns error for invalid syntax" do
      {:error, reason} = FeelNif.compile("if then else", %{})
      assert is_binary(reason)
      assert reason != ""
    end
  end

  # ---------------------------------------------------------------------------
  # 2. One-shot eval_expression
  # ---------------------------------------------------------------------------

  describe "eval_expression (parse + evaluate in one call)" do
    test "evaluates simple expression" do
      {:ok, result} = FeelNif.eval_expression("2 * 3", %{})
      assert result == 6
    end

    test "evaluates with context bindings" do
      {:ok, result} = FeelNif.eval_expression("amount * rate", %{"amount" => 100, "rate" => 0.15})
      assert_in_delta result, 15.0, 0.001
    end
  end

  # ---------------------------------------------------------------------------
  # 3. FEEL types — round-trip through NIF boundary
  # ---------------------------------------------------------------------------

  describe "FEEL type coverage" do
    test "boolean true" do
      {:ok, result} = FeelNif.eval_expression("true", %{})
      assert result == true
    end

    test "boolean false" do
      {:ok, result} = FeelNif.eval_expression("false", %{})
      assert result == false
    end

    test "null" do
      {:ok, result} = FeelNif.eval_expression("null", %{})
      assert result == nil
    end

    test "string" do
      {:ok, result} = FeelNif.eval_expression(~S("hello world"), %{})
      assert result == "hello world"
    end

    test "integer number" do
      {:ok, result} = FeelNif.eval_expression("42", %{})
      assert result == 42
    end

    test "float number" do
      {:ok, result} = FeelNif.eval_expression("3.14", %{})
      assert_in_delta result, 3.14, 0.001
    end

    test "list" do
      {:ok, result} = FeelNif.eval_expression("[1, 2, 3]", %{})
      assert result == [1, 2, 3]
    end

    test "context (map)" do
      {:ok, result} = FeelNif.eval_expression(~S({a: 1, b: "two"}), %{})
      assert is_map(result)
      assert result["a"] == 1
      assert result["b"] == "two"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Engine-relevant expression patterns (from SS8.5)
  # ---------------------------------------------------------------------------

  describe "conditional sequence flow patterns" do
    test "token.amount > 100" do
      ctx = %{"token" => %{"amount" => 150}}
      {:ok, result} = FeelNif.eval_expression("token.amount > 100", ctx)
      assert result == true
    end

    test "token.amount > 100 returns false" do
      ctx = %{"token" => %{"amount" => 50}}
      {:ok, result} = FeelNif.eval_expression("token.amount > 100", ctx)
      assert result == false
    end

    test "compound boolean condition" do
      ctx = %{"token" => %{"status" => "approved", "amount" => 3000}}
      expr = ~S(token.status = "approved" and token.amount <= 5000)
      {:ok, result} = FeelNif.eval_expression(expr, ctx)
      assert result == true
    end
  end

  describe "path access patterns" do
    test "simple path: token.orderId" do
      ctx = %{"token" => %{"orderId" => "ORD-123"}}
      {:ok, result} = FeelNif.eval_expression("token.orderId", ctx)
      assert result == "ORD-123"
    end

    test "deep nested path" do
      ctx = %{"token" => %{"order" => %{"customer" => %{"name" => "Alice"}}}}
      {:ok, result} = FeelNif.eval_expression("token.order.customer.name", ctx)
      assert result == "Alice"
    end
  end

  describe "if/then/else" do
    test "if true branch" do
      ctx = %{"token" => %{"priority" => 8}}
      expr = ~S(if token.priority > 5 then "urgent" else "normal")
      {:ok, result} = FeelNif.eval_expression(expr, ctx)
      assert result == "urgent"
    end

    test "if false branch" do
      ctx = %{"token" => %{"priority" => 2}}
      expr = ~S(if token.priority > 5 then "urgent" else "normal")
      {:ok, result} = FeelNif.eval_expression(expr, ctx)
      assert result == "normal"
    end
  end

  describe "list operations" do
    test "for/in/return" do
      ctx = %{"items" => [1, 2, 3]}
      {:ok, result} = FeelNif.eval_expression("for x in items return x * 2", ctx)
      assert result == [2, 4, 6]
    end

    test "some/satisfies" do
      ctx = %{"scores" => [70, 85, 95]}
      {:ok, result} = FeelNif.eval_expression("some x in scores satisfies x > 90", ctx)
      assert result == true
    end

    test "every/satisfies" do
      ctx = %{"scores" => [70, 85, 95]}
      {:ok, result} = FeelNif.eval_expression("every x in scores satisfies x > 60", ctx)
      assert result == true
    end

    test "every/satisfies false case" do
      ctx = %{"scores" => [70, 85, 95]}
      {:ok, result} = FeelNif.eval_expression("every x in scores satisfies x > 80", ctx)
      assert result == false
    end
  end

  describe "null propagation (FEEL three-valued logic)" do
    test "missing variable evaluates to null" do
      {:ok, result} = FeelNif.eval_expression("missing_var", %{"missing_var" => nil})
      assert result == nil
    end

    test "null arithmetic propagates" do
      {:ok, result} = FeelNif.eval_expression("missing_var + 5", %{"missing_var" => nil})
      assert result == nil
    end
  end

  describe "built-in functions" do
    test "string length" do
      {:ok, result} = FeelNif.eval_expression(~S|string length("hello")|, %{})
      assert result == 5
    end

    test "contains" do
      {:ok, result} = FeelNif.eval_expression(~S|contains("foobar", "bar")|, %{})
      assert result == true
    end

    test "count" do
      {:ok, result} = FeelNif.eval_expression(~S|count([1, 2, 3, 4])|, %{})
      assert result == 4
    end

    test "sum" do
      {:ok, result} = FeelNif.eval_expression(~S|sum([10, 20, 30])|, %{})
      assert result == 60
    end

    test "not" do
      {:ok, result} = FeelNif.eval_expression(~S|not(false)|, %{})
      assert result == true
    end
  end

  describe "temporal types" do
    test "date literal" do
      {:ok, result} = FeelNif.eval_expression(~S|@"2025-03-20"|, %{})
      assert {:feel_date, date_str} = result
      assert date_str =~ "2025-03-20"
    end

    test "date arithmetic (date + duration)" do
      {:ok, result} = FeelNif.eval_expression(~S|@"2025-03-20" + @"P10D"|, %{})
      assert {:feel_date, date_str} = result
      assert date_str =~ "2025-03-30"
    end

    test "duration literal" do
      {:ok, result} = FeelNif.eval_expression(~S|@"PT1H30M"|, %{})
      assert {:feel_duration_dt, _duration_str} = result
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Unary tests (for DMN / gateway conditions)
  # ---------------------------------------------------------------------------

  describe "unary tests" do
    test "less than" do
      {:ok, result} = FeelNif.eval_unary_test("< 100", 50, %{})
      assert result == true
    end

    test "less than — false" do
      {:ok, result} = FeelNif.eval_unary_test("< 100", 150, %{})
      assert result == false
    end

    test "range inclusive" do
      {:ok, result} = FeelNif.eval_unary_test("[1..5]", 3, %{})
      assert result == true
    end

    test "range exclusive — boundary" do
      {:ok, result} = FeelNif.eval_unary_test("(1..5)", 5, %{})
      assert result == false
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Full engine context shape (7 root bindings)
  # ---------------------------------------------------------------------------

  describe "full engine context shape" do
    test "evaluates expression with all 7 root bindings present" do
      ctx = %{
        "token" => %{"amount" => 500, "status" => "pending"},
        "this" => %{"id" => "Task_1", "name" => "Review Order", "type" => "userTask"},
        "context" => %{"department" => "sales"},
        "dataObjects" => %{"customerName" => "Alice"},
        "process" => %{"id" => "OrderProcess", "name" => "Order Process", "version" => "1.0"},
        "processInstance" => %{"id" => "pi-001", "startedAt" => "2025-01-15T10:00:00Z"},
        "identity" => %{"id" => "user-42", "name" => "Bob", "roles" => ["admin", "reviewer"]}
      }

      {:ok, result} = FeelNif.eval_expression("token.amount", ctx)
      assert result == 500

      {:ok, result} = FeelNif.eval_expression("this.name", ctx)
      assert result == "Review Order"

      {:ok, result} = FeelNif.eval_expression("dataObjects.customerName", ctx)
      assert result == "Alice"

      {:ok, result} = FeelNif.eval_expression("identity.name", ctx)
      assert result == "Bob"

      {:ok, result} = FeelNif.eval_expression("process.version", ctx)
      assert result == "1.0"
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Precompilation proof — performance sanity
  # ---------------------------------------------------------------------------

  describe "precompilation performance sanity" do
    test "compiled expression evaluates 1000 times without issue" do
      ctx = %{"x" => 0, "y" => 0}
      {:ok, ref} = FeelNif.compile("x * 2 + y", ctx)

      results =
        for i <- 1..1000 do
          {:ok, r} = FeelNif.eval_compiled(ref, %{"x" => i, "y" => i * 10})
          r
        end

      assert length(results) == 1000
      assert Enum.at(results, 0) == 12
      assert Enum.at(results, 999) == 12000
    end
  end
end
