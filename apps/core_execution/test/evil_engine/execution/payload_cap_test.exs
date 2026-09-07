Code.require_file(Path.expand("../../../../../test/support/payload_cap_fixtures.ex", __DIR__))

defmodule EvilEngine.Execution.PayloadCapTest do
  use ExUnit.Case, async: true

  alias EvilEngine.Execution.PayloadCap
  alias EvilEngine.Test.PayloadCapFixtures

  @small_limit 2048

  describe "check/2 with payloads within limit" do
    test "empty map passes" do
      assert :ok = PayloadCap.check(%{}, limit: @small_limit)
    end

    test "nil payload passes" do
      assert :ok = PayloadCap.check(nil, limit: @small_limit)
    end

    test "small map passes" do
      assert :ok = PayloadCap.check(%{"key" => "value"}, limit: @small_limit)
    end

    test "payload exactly at limit passes" do
      payload = String.duplicate("x", @small_limit)
      json_size = byte_size(Jason.encode!(payload))
      assert :ok = PayloadCap.check(payload, limit: json_size)
    end

    test "binary string is JSON-encoded for measurement" do
      binary = "hello"
      json_size = byte_size(Jason.encode!(binary))
      assert :ok = PayloadCap.check(binary, limit: json_size)
    end
  end

  describe "check/2 with payloads over limit" do
    test "payload one byte over limit fails" do
      payload = String.duplicate("x", @small_limit)
      json_size = byte_size(Jason.encode!(payload))

      assert {:error, :payload_too_large, details} =
               PayloadCap.check(payload, limit: json_size - 1)

      assert details.size == json_size
      assert details.limit == json_size - 1
      assert details.field == :payload
    end

    test "large nested structure fails" do
      payload = %{
        "data" =>
          Enum.map(1..500, fn i -> %{"index" => i, "value" => String.duplicate("x", 200)} end)
      }

      assert {:error, :payload_too_large, %{size: size, limit: limit}} =
               PayloadCap.check(payload, limit: 1024)

      assert size > 1024
      assert limit == 1024
    end

    test "custom field name propagated in error" do
      payload = String.duplicate("x", 2000)

      assert {:error, :payload_too_large, details} =
               PayloadCap.check(payload, limit: 1024, field: :fni_output)

      assert details.field == :fni_output
    end

    test "default field is :payload" do
      payload = String.duplicate("x", 2000)

      assert {:error, :payload_too_large, %{field: :payload}} =
               PayloadCap.check(payload, limit: 1024)
    end
  end

  describe "check/2 minimum cap floor" do
    test "limit below 1024 is raised to 1024" do
      small_payload = String.duplicate("x", 500)

      assert :ok = PayloadCap.check(small_payload, limit: 100)
    end

    test "payload over 1024 fails even with low configured limit" do
      payload = String.duplicate("x", 1500)

      assert {:error, :payload_too_large, %{limit: 1024}} =
               PayloadCap.check(payload, limit: 100)
    end
  end

  describe "check/2 with non-JSON-encodable terms" do
    test "non-encodable term returns encode error" do
      assert {:error, :encode_failed, %{reason: _}} =
               PayloadCap.check(self(), limit: @small_limit)
    end
  end

  describe "check/2 reads from application config" do
    test "uses configured token_max_bytes when no :limit option given" do
      configured = Application.get_env(:core_execution, :token_max_bytes, 65_536)

      payload_over = String.duplicate("x", configured + 100)

      assert {:error, :payload_too_large, %{limit: ^configured}} =
               PayloadCap.check(payload_over)
    end
  end

  describe "PayloadCapFixtures.mint_payload/1" do
    test "encoded size is exactly the requested target" do
      for target <- [1024, 65_536, 65_537] do
        payload = PayloadCapFixtures.mint_payload(target)
        assert PayloadCapFixtures.json_byte_size(payload) == target
      end
    end

    test "oversize_payload is one byte over the default cap" do
      assert PayloadCapFixtures.json_byte_size(PayloadCapFixtures.oversize_payload()) == 65_537
    end

    test "exactly_at_limit_payload matches the default cap" do
      assert PayloadCapFixtures.json_byte_size(PayloadCapFixtures.exactly_at_limit_payload()) ==
               65_536
    end
  end

  describe "parse_token_max_bytes/1" do
    test "nil and blank use the default 65536" do
      assert PayloadCap.parse_token_max_bytes(nil) == 65_536
      assert PayloadCap.parse_token_max_bytes("") == 65_536
    end

    test "explicit value below 1024 raises with minimum_required in the message" do
      error = assert_raise RuntimeError, fn -> PayloadCap.parse_token_max_bytes("512") end
      assert error.message =~ "minimum_required: 1024"
      assert error.message =~ "512"
    end

    test "explicit integer below 1024 raises" do
      error = assert_raise RuntimeError, fn -> PayloadCap.parse_token_max_bytes(512) end
      assert error.message =~ "minimum_required: 1024"
    end

    test "valid explicit value is returned unchanged" do
      assert PayloadCap.parse_token_max_bytes("2048") == 2048
      assert PayloadCap.parse_token_max_bytes(2048) == 2048
    end
  end
end
