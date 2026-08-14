defmodule Scry.Engine.Exqlite.WhereTranslator do
  @moduledoc """
  Translates a `Scry.Core.Query.t()`'s own `wheres` into a real SQL
  `WHERE` clause with bound `?` parameters, for `Scry.Engine.Exqlite`'s
  own `execute/3`. All-or-nothing: `translate/2` returns `:error` the
  moment *any* predicate anywhere in the tree can't be translated,
  never a partial clause silently narrowing what SQLite returns --
  there is no downstream re-verification left to catch an
  under-translated (row-dropping) predicate the way the old, lenient
  `fetch/3` contract's own re-application used to.

  A full recursive `{:and, l, r}`/`{:or, l, r}`/`{:not, p}` tree
  translates, not just a flat, implicitly-`AND`ed list of leaves --
  each combinator becomes its own parenthesized SQL group so operator
  precedence can never differ from what the predicate tree itself
  already encodes.

  Only `{:cmp, op, [field], value}` and `{:in, [field], values}` leaves
  are candidates, and only when: `field` is a single segment that's
  also a valid, safe-to-interpolate SQL identifier (a multi-segment
  path -- nested/JSON access -- is declined, not translated unchecked);
  `op` is one of `:eq`/`:not_eq`/`:lt`/`:gt`/`:le`/`:ge` (`:match` has
  no native SQLite equivalent); and every value involved (a literal, or
  a `{:param, name}` resolved against `params`) is a plain string,
  integer, or float, a `DateTime.t()`/`NaiveDateTime.t()` (see below),
  **or** the literal `nil` specifically for `:eq`/`:not_eq` --
  translated to `IS NULL`/`IS NOT NULL`, not a naive `= ?`/`!= ?` bound
  to `NULL` (SQL's own `x = NULL` is always `NULL`, never `TRUE`, so a
  literal translation there would silently change what the clause
  means). Booleans are deliberately never translated -- SQLite has no
  native boolean type, and guessing whether a column stores `0`/`1`
  integers or a real `SQLite ≥ 3.23` boolean literal isn't safe to
  assume.

  **A `DateTime.t()`/`NaiveDateTime.t()` literal binds as its own Unix
  epoch (microseconds) integer**, not an ISO 8601 string -- SQLite has
  no native timestamp type, so this module has to pick *some* concrete
  on-the-wire representation, and an integer sorts correctly under
  ordinary numeric comparison with no format/padding/timezone
  assumptions an ISO 8601 string comparison would otherwise carry. A
  column being compared against one **must itself be stored as the
  same epoch-microseconds integer**, or the comparison is comparing two
  genuinely different things; `Scry.Engine.Exqlite.SqlCompiler`'s own
  type-affinity check (`:numeric`, the same class a plain integer/float
  literal gets) is exactly what catches a column that isn't, declining
  the comparison rather than risk a silently wrong result.
  """

  alias Scry.Core.Query

  @op_sql %{eq: "=", not_eq: "!=", lt: "<", gt: ">", le: "<=", ge: ">="}
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Returns `{:ok, where_sql, params}` -- `where_sql` is either `""`
  (an empty `wheres`) or a `" WHERE ..."` fragment (leading space
  included, ready to append directly after a table/`GROUP BY` clause),
  `params` the bound values in the same left-to-right order as the `?`
  placeholders -- or `:error` the moment anything in `wheres` doesn't
  translate.
  """
  @spec translate([Query.predicate()], map()) :: {:ok, String.t(), [term()]} | :error
  def translate(wheres, params) do
    wheres
    |> Enum.reduce_while({:ok, []}, fn predicate, {:ok, acc} ->
      case translate_predicate(predicate, params) do
        {:ok, sql, bound} -> {:cont, {:ok, [{sql, bound} | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, []} ->
        {:ok, "", []}

      {:ok, reversed} ->
        {sql, bound} = build_clause(Enum.reverse(reversed))
        {:ok, sql, bound}

      :error ->
        :error
    end
  end

  defp build_clause(clauses) do
    {fragments, param_lists} = Enum.unzip(clauses)
    {" WHERE " <> Enum.join(fragments, " AND "), List.flatten(param_lists)}
  end

  # `{:cmp, op, lhs, nil}`'s own null-check idiom -- `field = NULL` is
  # always `NULL` in SQL, never `TRUE`, so this is a real, dedicated
  # translation, not the general clause below with `nil` bound as an
  # ordinary parameter.
  defp translate_predicate({:cmp, :eq, [field], nil}, _params) do
    if identifier?(field), do: {:ok, "#{field} IS NULL", []}, else: :error
  end

  defp translate_predicate({:cmp, :not_eq, [field], nil}, _params) do
    if identifier?(field), do: {:ok, "#{field} IS NOT NULL", []}, else: :error
  end

  defp translate_predicate({:cmp, op, [field], value}, params) do
    with {:ok, sql_op} <- Map.fetch(@op_sql, op),
         true <- identifier?(field),
         {:ok, resolved} <- resolve_value(value, params) do
      {:ok, "#{field} #{sql_op} ?", [resolved]}
    else
      _ -> :error
    end
  end

  defp translate_predicate({:in, [field], values}, params) when is_list(values) do
    with true <- identifier?(field),
         {:ok, resolved} when resolved != [] <- resolve_all(values, params) do
      placeholders = resolved |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")
      {:ok, "#{field} IN (#{placeholders})", resolved}
    else
      _ -> :error
    end
  end

  # `in` against a non-literal-list expr (a field/call expected to
  # resolve to a list at runtime) has no direct SQL translation without
  # a JSON table function -- declined, not attempted this increment.
  defp translate_predicate({:in, _lhs, _list_expr}, _params), do: :error

  defp translate_predicate({:and, l, r}, params) do
    with {:ok, sql_l, params_l} <- translate_predicate(l, params),
         {:ok, sql_r, params_r} <- translate_predicate(r, params) do
      {:ok, "(#{sql_l} AND #{sql_r})", params_l ++ params_r}
    else
      _ -> :error
    end
  end

  defp translate_predicate({:or, l, r}, params) do
    with {:ok, sql_l, params_l} <- translate_predicate(l, params),
         {:ok, sql_r, params_r} <- translate_predicate(r, params) do
      {:ok, "(#{sql_l} OR #{sql_r})", params_l ++ params_r}
    else
      _ -> :error
    end
  end

  defp translate_predicate({:not, p}, params) do
    case translate_predicate(p, params) do
      {:ok, sql, bound} -> {:ok, "NOT (#{sql})", bound}
      :error -> :error
    end
  end

  # A bare-path/`{:call, ...}`/`{:dot, ...}` `lhs` on a `:cmp` (rather
  # than the `[field]` single-segment shape every clause above already
  # matches) and anything else this module doesn't recognize.
  defp translate_predicate(_other, _params), do: :error

  defp resolve_all(values, params) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case resolve_value(value, params) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp resolve_value({:param, name}, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> bind_value(value)
      :error -> :error
    end
  end

  defp resolve_value(value, _params), do: bind_value(value)

  @doc "Whether `field` is a safe-to-interpolate SQL identifier -- also used by `Scry.Engine.Exqlite.SqlCompiler`."
  @spec identifier?(term()) :: boolean()
  def identifier?(field), do: is_binary(field) and Regex.match?(@identifier, field)

  @doc """
  `{:ok, bound_value}` for a value with a direct SQLite bind-parameter
  translation, `:error` otherwise. The epoch (microseconds)
  `%DateTime{}`/`%NaiveDateTime{}` encoding this module's own moduledoc
  documents -- also reused by `Scry.Engine.Exqlite.SqlCompiler`'s own
  type-affinity classification, so both sides of "how is a DateTime
  literal represented on the wire" stay in exactly one place.
  """
  @spec bind_value(term()) :: {:ok, String.t() | integer() | float()} | :error
  def bind_value(%DateTime{} = value), do: {:ok, DateTime.to_unix(value, :microsecond)}

  def bind_value(%NaiveDateTime{} = value),
    do: {:ok, NaiveDateTime.diff(value, ~N[1970-01-01 00:00:00], :microsecond)}

  def bind_value(value) when is_binary(value) or is_integer(value) or is_float(value),
    do: {:ok, value}

  def bind_value(_value), do: :error
end
