defmodule EvilEngine.Auth.JwksCacheTest do
  use ExUnit.Case, async: false

  alias EvilEngine.Auth.JwksCache

  describe "get_keys/0" do
    test "returns nil when no JWKS URL is configured" do
      assert JwksCache.get_keys() == nil
    end
  end
end
