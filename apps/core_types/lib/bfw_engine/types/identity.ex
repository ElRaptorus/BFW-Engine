defmodule BfwEngine.Types.Identity do
  @moduledoc """
  JWT-derived identity carried through every authenticated request.

  Extracted from the verified JWT by `api_auth`. The engine never
  re-checks claims after PI start (execution-detached model).

  ## Fields

  * `:id` — `sub` claim (required). For plugins: `"plugin:<name>"`.
  * `:roles` — list of role strings from the `roles` claim.
  * `:groups` — list of group strings from the `groups` claim.
  * `:claims` — full decoded JWT claim map (read-only reference).
  """

  @type t :: %__MODULE__{
          id: String.t(),
          roles: [String.t()],
          groups: [String.t()],
          claims: %{String.t() => term()}
        }

  @enforce_keys [:id]
  defstruct id: nil,
            roles: [],
            groups: [],
            claims: %{}
end
