defmodule EvilEngine.DMN.QualifiedReference do
  @moduledoc """
  Utilities for working with DMN qualified references.

  A qualified reference has the form `"namespace#elementId"` and is used
  in `InformationRequirement.required_decision_id` and similar fields
  to reference elements in imported DMN models.
  """

  @doc """
  Returns `true` when the reference contains a non-empty namespace
  and a non-empty element ID separated by `#`.
  """
  @spec imported?(String.t()) :: boolean()
  def imported?(reference) when is_binary(reference) do
    case String.split(reference, "#", parts: 2) do
      [namespace, element_id] when namespace != "" and element_id != "" -> true
      _ -> false
    end
  end

  @doc """
  Splits a qualified reference into `{namespace, element_id}`.

  Returns `{:imported, namespace, element_id}` for qualified references,
  `{:local, element_id}` for local references, or `:invalid` for malformed input.
  """
  @spec split(String.t()) :: {:imported, String.t(), String.t()} | {:local, String.t()} | :invalid
  def split(reference) when is_binary(reference) do
    case String.split(reference, "#", parts: 2) do
      [element_id] -> {:local, element_id}
      [_namespace, ""] -> :invalid
      ["", element_id] -> {:local, element_id}
      [namespace, element_id] -> {:imported, namespace, element_id}
    end
  end

  @doc """
  Extracts the namespace from a qualified reference.

  Returns the namespace string, or `"unknown"` if the reference
  is not a valid qualified reference.
  """
  @spec namespace(String.t()) :: String.t()
  def namespace(reference) when is_binary(reference) do
    case String.split(reference, "#", parts: 2) do
      [namespace, _element_id] when namespace != "" -> namespace
      _ -> "unknown"
    end
  end
end
