defmodule BfwEngine.Test do
  @moduledoc false

  # Test-only helpers may reach every namespace.
  use Boundary, check: [in: false, out: false]
end
