defmodule BfwEngine.DMN.Parser.SaxHandler.BoxedExpressions do
  @moduledoc """
  SAX handler functions for CL3 boxed expression elements:
  Context, ContextEntry, Invocation, Binding, List, Relation,
  Conditional, Filter, For, Every, and Some.

  Extracted from `SaxHandler` to keep that module focused on
  top-level DMN elements (Definitions, Decision, InputData, BKM,
  DecisionTable, etc.).

  All functions operate on and return the shared SAX parser state map.
  """

  alias BfwEngine.DMN.Model.Binding
  alias BfwEngine.DMN.Model.BoxedConditional
  alias BfwEngine.DMN.Model.BoxedContext
  alias BfwEngine.DMN.Model.BoxedEvery
  alias BfwEngine.DMN.Model.BoxedFilter
  alias BfwEngine.DMN.Model.BoxedFor
  alias BfwEngine.DMN.Model.BoxedInvocation
  alias BfwEngine.DMN.Model.BoxedList
  alias BfwEngine.DMN.Model.BoxedSome
  alias BfwEngine.DMN.Model.ContextEntry
  alias BfwEngine.DMN.Model.InformationItem
  alias BfwEngine.DMN.Model.LiteralExpression
  alias BfwEngine.DMN.Model.Relation

  @expression_parent_tags [
    :decision, :encapsulated_logic, :function_definition, :context_entry, :binding,
    :invocation, :list, :relation_row,
    :conditional_if, :conditional_then, :conditional_else,
    :filter_in, :filter_match,
    :for_in, :for_return,
    :every_in, :every_satisfies,
    :some_in, :some_satisfies
  ]

  # === Start element handlers =================================================

  def start_context(attrs, state) do
    state = push_context(state)
    context = %BoxedContext{id: attrs["id"]}
    {:ok, %{state | current_context: context, stack: [:context | state.stack]}}
  end

  def start_context_entry(_attrs, state) do
    state = push_context_entry(state)
    entry = %ContextEntry{}
    {:ok, %{state | current_context_entry: entry, stack: [:context_entry | state.stack]}}
  end

  def start_invocation(attrs, state) do
    state = push_invocation(state)
    invocation = %BoxedInvocation{id: attrs["id"]}
    {:ok, %{state | current_invocation: invocation, stack: [:invocation | state.stack]}}
  end

  def start_binding(_attrs, state) do
    binding = %Binding{}
    {:ok, %{state | current_binding: binding, stack: [:binding | state.stack]}}
  end

  def start_parameter(attrs, state) do
    parameter = %InformationItem{
      id: attrs["id"],
      name: attrs["name"] || "",
      type_ref: attrs["typeRef"]
    }

    %Binding{} = binding = state.current_binding
    {:ok, %{state | current_binding: %{binding | parameter: parameter}}}
  end

  def start_list(attrs, state) do
    state = push_list(state)
    list = %BoxedList{id: attrs["id"]}
    {:ok, %{state | current_list: list, stack: [:list | state.stack]}}
  end

  def start_relation(attrs, state) do
    state = push_relation(state)
    relation = %Relation{id: attrs["id"]}
    {:ok, %{state | current_relation: relation, stack: [:relation | state.stack]}}
  end

  def start_column(attrs, state) do
    column = %InformationItem{
      id: attrs["id"],
      name: attrs["name"] || "",
      type_ref: attrs["typeRef"]
    }

    %Relation{} = relation = state.current_relation
    {:ok, %{state | current_relation: %{relation | columns: relation.columns ++ [column]}}}
  end

  def start_row(_attrs, state) do
    {:ok, %{state | current_relation_row: [], stack: [:relation_row | state.stack]}}
  end

  def start_conditional(attrs, state) do
    state = push_conditional(state)
    conditional = %BoxedConditional{id: attrs["id"]}
    {:ok, %{state | current_conditional: conditional, stack: [:conditional | state.stack]}}
  end

  def start_if(state), do: {:ok, %{state | stack: [:conditional_if | state.stack]}}
  def start_then(state), do: {:ok, %{state | stack: [:conditional_then | state.stack]}}
  def start_else(state), do: {:ok, %{state | stack: [:conditional_else | state.stack]}}

  def start_filter(attrs, state) do
    state = push_filter(state)
    boxed_filter = %BoxedFilter{id: attrs["id"]}
    {:ok, %{state | current_filter: boxed_filter, stack: [:filter | state.stack]}}
  end

  def start_filter_in(state), do: {:ok, %{state | stack: [:filter_in | state.stack]}}
  def start_filter_match(state), do: {:ok, %{state | stack: [:filter_match | state.stack]}}

  def start_for(attrs, state) do
    state = push_for(state)
    boxed_for = %BoxedFor{id: attrs["id"], iterator_variable: attrs["iteratorVariable"]}
    {:ok, %{state | current_for: boxed_for, stack: [:for | state.stack]}}
  end

  def start_for_in(state), do: {:ok, %{state | stack: [:for_in | state.stack]}}
  def start_for_return(state), do: {:ok, %{state | stack: [:for_return | state.stack]}}

  def start_every(attrs, state) do
    state = push_every(state)
    boxed_every = %BoxedEvery{id: attrs["id"], iterator_variable: attrs["iteratorVariable"]}
    {:ok, %{state | current_every: boxed_every, stack: [:every | state.stack]}}
  end

  def start_every_in(state), do: {:ok, %{state | stack: [:every_in | state.stack]}}
  def start_every_satisfies(state), do: {:ok, %{state | stack: [:every_satisfies | state.stack]}}

  def start_some(attrs, state) do
    state = push_some(state)
    boxed_some = %BoxedSome{id: attrs["id"], iterator_variable: attrs["iteratorVariable"]}
    {:ok, %{state | current_some: boxed_some, stack: [:some | state.stack]}}
  end

  def start_some_in(state), do: {:ok, %{state | stack: [:some_in | state.stack]}}
  def start_some_satisfies(state), do: {:ok, %{state | stack: [:some_satisfies | state.stack]}}

  # === End element handlers ===================================================

  def end_context_entry(state) do
    entry = state.current_context_entry
    %BoxedContext{} = context = state.current_context
    updated_context = %{context | context_entries: context.context_entries ++ [entry]}
    state = pop_context_entry(state)
    {:ok, %{state | current_context: updated_context, stack: tl(state.stack)}}
  end

  def end_context(state) do
    completed_context = state.current_context
    state = pop_context(state)
    state = %{state | stack: tl(state.stack)}
    state = attach_completed_expression(state, completed_context)
    {:ok, state}
  end

  def end_binding(state) do
    binding = state.current_binding
    %BoxedInvocation{} = invocation = state.current_invocation
    updated = %{invocation | bindings: invocation.bindings ++ [binding]}
    {:ok, %{state | current_invocation: updated, current_binding: nil, stack: tl(state.stack)}}
  end

  def end_invocation(state) do
    completed_invocation = state.current_invocation
    state = pop_invocation(state)
    state = %{state | stack: tl(state.stack)}
    state = attach_completed_expression(state, completed_invocation)
    {:ok, state}
  end

  def end_list(state) do
    completed_list = %{state.current_list | elements: Enum.reverse(state.current_list.elements)}
    state = pop_list(state)
    state = %{state | stack: tl(state.stack)}
    state = attach_completed_expression(state, completed_list)
    {:ok, state}
  end

  def end_row(state) do
    row_expressions = Enum.reverse(state.current_relation_row)
    %Relation{} = relation = state.current_relation
    updated = %{relation | rows: relation.rows ++ [row_expressions]}
    {:ok, %{state | current_relation: updated, current_relation_row: nil, stack: tl(state.stack)}}
  end

  def end_relation(state) do
    completed_relation = state.current_relation
    state = pop_relation(state)
    state = %{state | stack: tl(state.stack)}
    state = attach_completed_expression(state, completed_relation)
    {:ok, state}
  end

  def end_conditional_branch(state), do: {:ok, %{state | stack: tl(state.stack)}}

  def end_conditional(state) do
    completed_conditional = state.current_conditional
    state = pop_conditional(state)
    state = %{state | stack: tl(state.stack)}
    state = attach_completed_expression(state, completed_conditional)
    {:ok, state}
  end

  def end_filter_child(state), do: {:ok, %{state | stack: tl(state.stack)}}

  def end_filter(state) do
    completed_filter = state.current_filter
    state = pop_filter(state)
    state = %{state | stack: tl(state.stack)}
    state = attach_completed_expression(state, completed_filter)
    {:ok, state}
  end

  def end_for_child(state), do: {:ok, %{state | stack: tl(state.stack)}}

  def end_for(state) do
    completed_for = state.current_for
    state = pop_for(state)
    state = %{state | stack: tl(state.stack)}
    state = attach_completed_expression(state, completed_for)
    {:ok, state}
  end

  def end_every_child(state), do: {:ok, %{state | stack: tl(state.stack)}}

  def end_every(state) do
    completed_every = state.current_every
    state = pop_every(state)
    state = %{state | stack: tl(state.stack)}
    state = attach_completed_expression(state, completed_every)
    {:ok, state}
  end

  def end_some_child(state), do: {:ok, %{state | stack: tl(state.stack)}}

  def end_some(state) do
    completed_some = state.current_some
    state = pop_some(state)
    state = %{state | stack: tl(state.stack)}
    state = attach_completed_expression(state, completed_some)
    {:ok, state}
  end

  # === Expression attachment ==================================================

  @doc """
  Attaches a completed expression to its parent element based on
  the current stack position.
  """
  def attach_completed_expression(state, expression) do
    state.stack
    |> find_expression_parent()
    |> do_attach(state, expression)
  end

  defp do_attach(:decision, state, expression) do
    decision = state.current_decision
    %{state | current_decision: %{decision | expression: expression}}
  end

  defp do_attach(:encapsulated_logic, state, expression), do: attach_to_function_definition(state, expression)
  defp do_attach(:function_definition, state, expression), do: attach_to_function_definition(state, expression)

  defp do_attach(:context_entry, state, expression) do
    %ContextEntry{} = entry = state.current_context_entry
    %{state | current_context_entry: %{entry | expression: expression}}
  end

  defp do_attach(:binding, state, expression) do
    %Binding{} = binding = state.current_binding
    %{state | current_binding: %{binding | expression: expression}}
  end

  defp do_attach(:invocation, state, expression) do
    %BoxedInvocation{} = invocation = state.current_invocation

    if is_nil(invocation.called_function) do
      name = extract_called_function_name(expression)
      %{state | current_invocation: %{invocation | called_function: name}}
    else
      state
    end
  end

  defp do_attach(:list, state, expression) do
    %BoxedList{} = list = state.current_list
    %{state | current_list: %{list | elements: [expression | list.elements]}}
  end

  defp do_attach(:relation_row, state, expression) do
    %{state | current_relation_row: [expression | state.current_relation_row]}
  end

  defp do_attach(:conditional_if, state, expression) do
    %BoxedConditional{} = conditional = state.current_conditional
    %{state | current_conditional: %{conditional | if_expression: expression}}
  end

  defp do_attach(:conditional_then, state, expression) do
    %BoxedConditional{} = conditional = state.current_conditional
    %{state | current_conditional: %{conditional | then_expression: expression}}
  end

  defp do_attach(:conditional_else, state, expression) do
    %BoxedConditional{} = conditional = state.current_conditional
    %{state | current_conditional: %{conditional | else_expression: expression}}
  end

  defp do_attach(:filter_in, state, expression) do
    %BoxedFilter{} = boxed_filter = state.current_filter
    %{state | current_filter: %{boxed_filter | in_expression: expression}}
  end

  defp do_attach(:filter_match, state, expression) do
    %BoxedFilter{} = boxed_filter = state.current_filter
    %{state | current_filter: %{boxed_filter | match_expression: expression}}
  end

  defp do_attach(:for_in, state, expression) do
    %BoxedFor{} = boxed_for = state.current_for
    %{state | current_for: %{boxed_for | in_expression: expression}}
  end

  defp do_attach(:for_return, state, expression) do
    %BoxedFor{} = boxed_for = state.current_for
    %{state | current_for: %{boxed_for | return_expression: expression}}
  end

  defp do_attach(:every_in, state, expression) do
    %BoxedEvery{} = boxed_every = state.current_every
    %{state | current_every: %{boxed_every | in_expression: expression}}
  end

  defp do_attach(:every_satisfies, state, expression) do
    %BoxedEvery{} = boxed_every = state.current_every
    %{state | current_every: %{boxed_every | satisfies_expression: expression}}
  end

  defp do_attach(:some_in, state, expression) do
    %BoxedSome{} = boxed_some = state.current_some
    %{state | current_some: %{boxed_some | in_expression: expression}}
  end

  defp do_attach(:some_satisfies, state, expression) do
    %BoxedSome{} = boxed_some = state.current_some
    %{state | current_some: %{boxed_some | satisfies_expression: expression}}
  end

  defp do_attach(nil, state, _expression), do: state

  defp attach_to_function_definition(state, expression) do
    function_definition = state.current_function_definition
    %{state | current_function_definition: %{function_definition | body: expression}}
  end

  defp extract_called_function_name(%LiteralExpression{text: text}) when is_binary(text), do: text
  defp extract_called_function_name(_expression), do: nil

  defp find_expression_parent(stack) do
    Enum.find(stack, fn tag -> tag in @expression_parent_tags end)
  end

  # === Stack push/pop helpers for nestable expression types ==================

  defp push_context(state) do
    if state.current_context do
      %{state | context_stack: [state.current_context | state.context_stack]}
    else
      state
    end
  end

  defp pop_context(state) do
    case state.context_stack do
      [parent | rest] -> %{state | current_context: parent, context_stack: rest}
      [] -> %{state | current_context: nil}
    end
  end

  defp push_context_entry(state) do
    if state.current_context_entry do
      %{state | context_entry_stack: [state.current_context_entry | state.context_entry_stack]}
    else
      state
    end
  end

  defp pop_context_entry(state) do
    case state.context_entry_stack do
      [parent | rest] -> %{state | current_context_entry: parent, context_entry_stack: rest}
      [] -> %{state | current_context_entry: nil}
    end
  end

  defp push_invocation(state) do
    if state.current_invocation do
      %{state | invocation_stack: [state.current_invocation | state.invocation_stack]}
    else
      state
    end
  end

  defp pop_invocation(state) do
    case state.invocation_stack do
      [parent | rest] -> %{state | current_invocation: parent, invocation_stack: rest}
      [] -> %{state | current_invocation: nil}
    end
  end

  defp push_list(state) do
    if state.current_list do
      %{state | list_stack: [state.current_list | state.list_stack]}
    else
      state
    end
  end

  defp pop_list(state) do
    case state.list_stack do
      [parent | rest] -> %{state | current_list: parent, list_stack: rest}
      [] -> %{state | current_list: nil}
    end
  end

  defp push_relation(state) do
    if state.current_relation do
      %{state | relation_stack: [state.current_relation | state.relation_stack]}
    else
      state
    end
  end

  defp pop_relation(state) do
    case state.relation_stack do
      [parent | rest] -> %{state | current_relation: parent, relation_stack: rest}
      [] -> %{state | current_relation: nil}
    end
  end

  defp push_conditional(state) do
    if state.current_conditional do
      %{state | conditional_stack: [state.current_conditional | state.conditional_stack]}
    else
      state
    end
  end

  defp pop_conditional(state) do
    case state.conditional_stack do
      [parent | rest] -> %{state | current_conditional: parent, conditional_stack: rest}
      [] -> %{state | current_conditional: nil}
    end
  end

  defp push_filter(state) do
    if state.current_filter do
      %{state | filter_stack: [state.current_filter | state.filter_stack]}
    else
      state
    end
  end

  defp pop_filter(state) do
    case state.filter_stack do
      [parent | rest] -> %{state | current_filter: parent, filter_stack: rest}
      [] -> %{state | current_filter: nil}
    end
  end

  defp push_for(state) do
    if state.current_for do
      %{state | for_stack: [state.current_for | state.for_stack]}
    else
      state
    end
  end

  defp pop_for(state) do
    case state.for_stack do
      [parent | rest] -> %{state | current_for: parent, for_stack: rest}
      [] -> %{state | current_for: nil}
    end
  end

  defp push_every(state) do
    if state.current_every do
      %{state | every_stack: [state.current_every | state.every_stack]}
    else
      state
    end
  end

  defp pop_every(state) do
    case state.every_stack do
      [parent | rest] -> %{state | current_every: parent, every_stack: rest}
      [] -> %{state | current_every: nil}
    end
  end

  defp push_some(state) do
    if state.current_some do
      %{state | some_stack: [state.current_some | state.some_stack]}
    else
      state
    end
  end

  defp pop_some(state) do
    case state.some_stack do
      [parent | rest] -> %{state | current_some: parent, some_stack: rest}
      [] -> %{state | current_some: nil}
    end
  end
end
