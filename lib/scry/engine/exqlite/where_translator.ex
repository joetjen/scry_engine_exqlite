defmodule Scry.Engine.Exqlite.WhereTranslator do
  @moduledoc """
  Translates whatever it can recognize out of a `Scry.Core.Query.t()`'s
  own `wheres` into a real SQL `WHERE` clause with bound `?`
  parameters, for `Scry.Engine.Exqlite.fetch/3`'s own pushdown. Anything
  it can't translate is simply left out of the clause -- `wheres` is a
  list of predicates the caller already combines with `and`
  (`Scry.Core.Query`'s own moduledoc), so dropping an untranslatable
  entry only ever *widens* what SQLite itself returns, never narrows
  it; `Scry.Core.Executor` re-checks every predicate afterward
  regardless; this module only ever needs to be correct, never
  complete.

  A top-level `{:and, left, right}` chain among `wheres` is flattened
  first, so e.g. `WHERE id = 1 AND status = "active"` still gets both
  legs pushed down even though they arrive as one nested predicate, not
  two list entries.

  Only `{:cmp, op, [field], value}` leaves are candidates, and only
  when all three hold: `op` is one of `:eq`/`:not_eq`/`:lt`/`:gt`/`:le`/
  `:ge` (`:match` has no direct SQL equivalent); `field` is a single
  segment that's also a valid, safe-to-interpolate SQL identifier (a
  multi-segment path, or one that isn't, is left untranslated -- never
  built into the SQL string unchecked); and `value` is a plain string,
  integer, or float. `nil`, booleans, `{:field, ...}`, and
  `{:param, ...}` are deliberately never translated: SQL's own `=
  NULL`/boolean-as-integer semantics don't reliably match this
  project's own comparison semantics (a naive translation risks
  *under*-inclusion -- silently dropping a row a correct fetch would
  have returned -- which is the one direction `Scry.Core.Executor`'s
  own re-verification can never catch, per `Scry.Core.EngineBehaviour`'s
  own safety invariant), and a `{:param, ...}` value isn't available at
  translation time at all (`fetch/3` isn't handed `params`).

  `translate_strict/2` (below) is a separate, stricter entry point for
  `aggregate/5`'s own pushdown, which *is* handed `params` and *does*
  need `{:param, ...}` translated -- see its own doc for why its
  all-or-nothing contract has to differ from this function's leniency.
  """

  alias Scry.Core.Query

  @op_sql %{eq: "=", not_eq: "!=", lt: "<", gt: ">", le: "<=", ge: ">="}
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Returns `{where_sql, params}` -- `where_sql` is either `""` (nothing
  translatable) or a `" WHERE ..."` fragment (leading space included,
  ready to append directly after a table name), `params` the bound
  values in the same left-to-right order as the `?` placeholders.
  """
  @spec translate([Query.predicate()]) :: {String.t(), [term()]}
  def translate(wheres) do
    wheres
    |> Enum.flat_map(&flatten_and/1)
    |> Enum.flat_map(&translate_leaf/1)
    |> build_clause()
  end

  @doc """
  Like `translate/1`, but for `Scry.Engine.Exqlite.aggregate/5`'s own
  genuinely stricter, all-or-nothing requirement -- grouping is
  irreversible, so there's no safe way to apply a leftover,
  untranslated predicate *after* SQL has already aggregated rows away,
  the way `translate/1`'s own leniency (silently drop what can't be
  translated, `Scry.Core.Executor` re-checks everything downstream
  regardless) relies on. Returns `:error` the moment *any* `wheres`
  predicate can't be translated, rather than silently narrowing.

  Also resolves `{:param, name}` against `bound_params` -- `translate/1`
  never does this (`fetch/3` isn't handed `params` at all), but
  `aggregate/5` is, so a query filtering by a runtime-bound value (the
  overwhelmingly common real case) can still reach 100% translatability
  instead of declining pushdown outright.
  """
  @spec translate_strict([Query.predicate()], map()) :: {:ok, String.t(), [term()]} | :error
  def translate_strict(wheres, bound_params) do
    wheres
    |> Enum.flat_map(&flatten_and/1)
    |> Enum.reduce_while({:ok, []}, fn predicate, {:ok, acc} ->
      case translate_leaf_strict(predicate, bound_params) do
        {:ok, clause} -> {:cont, {:ok, [clause | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed_clauses} ->
        {where_sql, params} = build_clause(Enum.reverse(reversed_clauses))
        {:ok, where_sql, params}

      :error ->
        :error
    end
  end

  defp flatten_and({:and, left, right}), do: flatten_and(left) ++ flatten_and(right)
  defp flatten_and(predicate), do: [predicate]

  defp translate_leaf({:cmp, op, [field], value}) do
    with {:ok, sql_op} <- Map.fetch(@op_sql, op),
         true <- identifier?(field),
         true <- literal?(value) do
      [{"#{field} #{sql_op} ?", value}]
    else
      _ -> []
    end
  end

  defp translate_leaf(_predicate), do: []

  defp translate_leaf_strict({:cmp, op, [field], value}, bound_params) do
    with {:ok, sql_op} <- Map.fetch(@op_sql, op),
         true <- identifier?(field),
         {:ok, resolved} <- resolve_strict_value(value, bound_params) do
      {:ok, {"#{field} #{sql_op} ?", resolved}}
    else
      _ -> :error
    end
  end

  defp translate_leaf_strict(_predicate, _bound_params), do: :error

  defp resolve_strict_value({:param, name}, bound_params) do
    case Map.fetch(bound_params, name) do
      {:ok, value} -> if literal?(value), do: {:ok, value}, else: :error
      :error -> :error
    end
  end

  defp resolve_strict_value(value, _bound_params) do
    if literal?(value), do: {:ok, value}, else: :error
  end

  defp identifier?(field), do: is_binary(field) and Regex.match?(@identifier, field)

  defp literal?(value), do: is_binary(value) or is_integer(value) or is_float(value)

  defp build_clause([]), do: {"", []}

  defp build_clause(clauses) do
    {fragments, params} = Enum.unzip(clauses)
    {" WHERE " <> Enum.join(fragments, " AND "), params}
  end
end
