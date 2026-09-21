defmodule BfwEngine.DMN.FeelBuiltinFunctionsTest do
  @moduledoc """
  Systematic audit of DMN-mandated FEEL built-in function support
  via the dsntk Rust NIF. Tests document which functions are supported,
  which return unexpected results, and which are unsupported.

  Reference: DMN 1.5 §10.3.4 (Built-in functions)
  """

  use ExUnit.Case, async: true

  alias BfwEngine.Expressions

  defp feel_eval(expression, context \\ %{}) do
    Expressions.eval(expression, context)
  end

  # =========================================================================
  # Conversion functions
  # =========================================================================

  describe "FEEL conversion functions" do
    @tag :dsntk_limitation
    test "number(from) — dsntk returns nil (unsupported)" do
      assert {:ok, nil} = feel_eval(~s|number("42")|)
    end

    test "string(from)" do
      assert {:ok, "42"} = feel_eval("string(42)")
    end
  end

  # =========================================================================
  # Boolean functions
  # =========================================================================

  describe "FEEL boolean functions" do
    test "not(value)" do
      assert {:ok, false} = feel_eval("not(true)")
      assert {:ok, true} = feel_eval("not(false)")
    end
  end

  # =========================================================================
  # String functions
  # =========================================================================

  describe "FEEL string functions" do
    test "substring(string, start position)" do
      assert {:ok, "llo"} = feel_eval(~s|substring("hello", 3)|)
    end

    test "substring(string, start position, length)" do
      assert {:ok, "el"} = feel_eval(~s|substring("hello", 2, 2)|)
    end

    test "string length(string)" do
      assert {:ok, 5} = feel_eval(~s|string length("hello")|)
    end

    test "upper case(string)" do
      assert {:ok, "HELLO"} = feel_eval(~s|upper case("hello")|)
    end

    test "lower case(string)" do
      assert {:ok, "hello"} = feel_eval(~s|lower case("HELLO")|)
    end

    test "contains(string, match)" do
      assert {:ok, true} = feel_eval(~s|contains("hello world", "world")|)
      assert {:ok, false} = feel_eval(~s|contains("hello", "xyz")|)
    end

    test "starts with(string, match)" do
      assert {:ok, true} = feel_eval(~s|starts with("hello", "hel")|)
      assert {:ok, false} = feel_eval(~s|starts with("hello", "xyz")|)
    end

    test "ends with(string, match)" do
      assert {:ok, true} = feel_eval(~s|ends with("hello", "llo")|)
      assert {:ok, false} = feel_eval(~s|ends with("hello", "xyz")|)
    end

    test "matches(input, pattern)" do
      assert {:ok, true} = feel_eval(~s|matches("hello123", "[a-z]+[0-9]+")|)
      assert {:ok, false} = feel_eval(~s|matches("hello", "[0-9]+")|)
    end

    test "replace(input, pattern, replacement)" do
      result = feel_eval(~s|replace("hello", "(.)", "$1-")|)
      assert {:ok, value} = result
      assert is_binary(value)
    end

    test "split(string, delimiter)" do
      result = feel_eval(~s|split("a,b,c", ",")|)
      assert {:ok, ["a", "b", "c"]} = result
    end
  end

  # =========================================================================
  # List functions
  # =========================================================================

  describe "FEEL list functions" do
    test "list contains(list, element)" do
      assert {:ok, true} = feel_eval("list contains([1,2,3], 2)")
      assert {:ok, false} = feel_eval("list contains([1,2,3], 5)")
    end

    test "count(list)" do
      assert {:ok, 3} = feel_eval("count([1,2,3])")
      assert {:ok, 0} = feel_eval("count([])")
    end

    test "min(list)" do
      assert {:ok, 1} = feel_eval("min([3,1,2])")
    end

    test "max(list)" do
      assert {:ok, 3} = feel_eval("max([3,1,2])")
    end

    test "sum(list)" do
      assert {:ok, 6} = feel_eval("sum([1,2,3])")
    end

    test "mean(list)" do
      assert {:ok, value} = feel_eval("mean([1,2,3])")
      assert_in_delta value, 2.0, 0.001
    end

    test "distinct values(list)" do
      assert {:ok, values} = feel_eval("distinct values([1,2,2,3,3])")
      assert Enum.sort(values) == [1, 2, 3]
    end

    test "flatten(list)" do
      assert {:ok, [1, 2, 3, 4]} = feel_eval("flatten([[1,2],[3,4]])")
    end

    test "sort(list, precedes)" do
      result = feel_eval("sort([3,1,2], function(x,y) x < y)")
      assert {:ok, [1, 2, 3]} = result
    end

    test "reverse(list)" do
      assert {:ok, [3, 2, 1]} = feel_eval("reverse([1,2,3])")
    end

    test "index of(list, match)" do
      assert {:ok, [2]} = feel_eval("index of([1,2,3], 2)")
    end

    test "append(list, item)" do
      assert {:ok, [1, 2, 3, 4]} = feel_eval("append([1,2,3], 4)")
    end

    test "concatenate(list1, list2)" do
      assert {:ok, [1, 2, 3, 4]} = feel_eval("concatenate([1,2], [3,4])")
    end

    test "sublist(list, start position)" do
      assert {:ok, [3, 4, 5]} = feel_eval("sublist([1,2,3,4,5], 3)")
    end

    test "sublist(list, start position, length)" do
      assert {:ok, [2, 3]} = feel_eval("sublist([1,2,3,4,5], 2, 2)")
    end

    test "insert before(list, position, newItem)" do
      assert {:ok, [1, 99, 2, 3]} = feel_eval("insert before([1,2,3], 2, 99)")
    end

    test "remove(list, position)" do
      assert {:ok, [1, 3]} = feel_eval("remove([1,2,3], 2)")
    end

    test "union(list1, list2)" do
      assert {:ok, values} = feel_eval("union([1,2], [2,3])")
      assert Enum.sort(values) == [1, 2, 3]
    end

    test "product(list)" do
      assert {:ok, 24} = feel_eval("product([1,2,3,4])")
    end

    test "median(list)" do
      assert {:ok, 2} = feel_eval("median([1,2,3])")
    end

    test "stddev(list)" do
      result = feel_eval("stddev([2,4,7,5])")
      case result do
        {:ok, value} when is_number(value) -> assert value > 0
        _ -> flunk("stddev should return a number, got: #{inspect(result)}")
      end
    end

    test "mode(list)" do
      assert {:ok, [2]} = feel_eval("mode([1,2,2,3])")
    end

    test "all(list)" do
      assert {:ok, true} = feel_eval("all([true, true, true])")
      assert {:ok, false} = feel_eval("all([true, false, true])")
    end

    test "any(list)" do
      assert {:ok, true} = feel_eval("any([false, true, false])")
      assert {:ok, false} = feel_eval("any([false, false, false])")
    end
  end

  # =========================================================================
  # Numeric functions
  # =========================================================================

  describe "FEEL numeric functions" do
    test "decimal(n, scale)" do
      assert {:ok, 1.33} = feel_eval("decimal(1.333, 2)")
    end

    test "floor(n)" do
      assert {:ok, 1} = feel_eval("floor(1.7)")
    end

    test "ceiling(n)" do
      assert {:ok, 2} = feel_eval("ceiling(1.2)")
    end

    test "abs(n)" do
      assert {:ok, 5} = feel_eval("abs(-5)")
    end

    test "modulo(dividend, divisor)" do
      assert {:ok, 1} = feel_eval("modulo(7, 3)")
    end

    test "sqrt(n)" do
      assert {:ok, result} = feel_eval("sqrt(16)")
      assert_in_delta result, 4.0, 0.001
    end

    test "log(n)" do
      result = feel_eval("log(1)")
      case result do
        {:ok, value} -> assert_in_delta value, 0.0, 0.001
        _ -> flunk("log(1) should return 0, got: #{inspect(result)}")
      end
    end

    test "exp(n)" do
      result = feel_eval("exp(0)")
      case result do
        {:ok, value} -> assert_in_delta value, 1.0, 0.001
        _ -> flunk("exp(0) should return 1, got: #{inspect(result)}")
      end
    end

    test "odd(n)" do
      assert {:ok, true} = feel_eval("odd(3)")
      assert {:ok, false} = feel_eval("odd(4)")
    end

    test "even(n)" do
      assert {:ok, true} = feel_eval("even(4)")
      assert {:ok, false} = feel_eval("even(3)")
    end
  end

  # =========================================================================
  # Date/time functions
  # =========================================================================

  describe "FEEL date/time functions" do
    test "date(string)" do
      result = feel_eval(~s|date("2026-05-21")|)
      assert {:ok, _date} = result
    end

    test "time(string)" do
      result = feel_eval(~s|time("10:30:00")|)
      assert {:ok, _time} = result
    end

    test "date and time(string)" do
      result = feel_eval(~s|date and time("2026-05-21T10:30:00")|)
      assert {:ok, _dt} = result
    end

    test "now()" do
      result = feel_eval("now()")
      assert {:ok, _now} = result
    end

    test "today()" do
      result = feel_eval("today()")
      assert {:ok, _today} = result
    end

    test "day of week(date)" do
      result = feel_eval(~s|day of week(date("2026-05-21"))|)
      assert {:ok, _day} = result
    end

    test "month of year(date)" do
      result = feel_eval(~s|month of year(date("2026-05-21"))|)
      assert {:ok, _month} = result
    end
  end

  # =========================================================================
  # Context functions
  # =========================================================================

  describe "FEEL context functions" do
    test "get value(context, key)" do
      assert {:ok, 42} = feel_eval(~s|get value({a: 42, b: 99}, "a")|)
    end

    test "get entries(context)" do
      result = feel_eval("get entries({a: 1, b: 2})")
      assert {:ok, entries} = result
      assert is_list(entries)
    end

    test "context put(context, key, value)" do
      result = feel_eval(~s|context put({a: 1}, "b", 2)|)
      case result do
        {:ok, map} when is_map(map) -> assert Map.get(map, "b") == 2 or Map.get(map, :b) == 2
        _ -> flunk("context put should return a map, got: #{inspect(result)}")
      end
    end

    test "context merge(contexts)" do
      result = feel_eval("context merge([{a: 1}, {b: 2}])")
      case result do
        {:ok, map} when is_map(map) -> assert map_size(map) >= 2
        _ -> flunk("context merge should return a map, got: #{inspect(result)}")
      end
    end
  end

  # =========================================================================
  # Range functions
  # =========================================================================

  describe "FEEL range functions" do
    test "before(point, range)" do
      assert {:ok, true} = feel_eval("before(1, [5..10])")
      assert {:ok, false} = feel_eval("before(7, [5..10])")
    end

    test "after(point, range)" do
      assert {:ok, true} = feel_eval("after(15, [5..10])")
      assert {:ok, false} = feel_eval("after(7, [5..10])")
    end
  end

  # =========================================================================
  # Conditional and type functions
  # =========================================================================

  describe "FEEL type and conditional functions" do
    test "if-then-else" do
      assert {:ok, "yes"} = feel_eval(~s|if true then "yes" else "no"|)
      assert {:ok, "no"} = feel_eval(~s|if false then "yes" else "no"|)
    end

    test "instance of" do
      assert {:ok, true} = feel_eval("42 instance of number")
      assert {:ok, true} = feel_eval(~s|"hello" instance of string|)
    end
  end
end
