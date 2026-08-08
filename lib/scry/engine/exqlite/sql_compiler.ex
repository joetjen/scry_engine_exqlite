defmodule Scry.Engine.Exqlite.SqlCompiler do
  @moduledoc """
  Compiles a flat `Scry.Core.Query.t()` into one native SQL statement
  -- `WHERE`/`GROUP BY`/aggregates/`ORDER BY`/`DISTINCT`/`LIMIT`/
  `OFFSET`/projection, all in one query -- for `Scry.Engine.Exqlite`'s
  own `execute/3`. All-or-nothing, like every compiler in this new
  `Scry.Core.EngineBehaviour.execute/3` generation: `compile/2` returns
  `{:error, {:unsupported, detail}}` the moment *anything* in `query`
  falls outside what this module translates, never a partial statement
  silently dropping part of the query's own semantics -- there is no
  downstream re-verification left to catch that.

  ## What compiles

  - `wheres`: delegated to `Scry.Engine.Exqlite.WhereTranslator`, whose
    own moduledoc has the exact predicate shapes it accepts.
  - A **plain** (non-aggregate) query: every `select` item must be a
    bare, single-segment `{:field, [column]}`, optionally under an
    explicit alias (`{:computed, alias, {:field, [column]}}` --
    `Scry.Core.Query.from/2`'s own map-shaped `select:` always wraps
    every entry this way, even a plain field reference) -- a genuine
    computed expression (a cast, arithmetic, `WHEN`, a window function)
    has no translation here and declines the whole query, not just
    that one item.
  - An **aggregate**-shaped query (`group_bys != []`, or any
    `sum`/`avg`/`count`/`min`/`max` call anywhere in `select`):
    `group_mode: :plain` only (`ROLLUP`/`CUBE` decline); every
    `select` item is either a bare field (optionally aliased, same as
    above) matching one of `group_bys` exactly, or one of `sum`/`avg`/
    `count`/`min`/`max` called with exactly one bare-field argument
    (`count(distinct field)` included); `havings == []` (a real
    `HAVING` clause is a genuinely separate translation problem,
    deferred, not attempted this increment).
  - `order_bys`: every entry a bare, single-segment field.
  - `distinct`/`limit`/`offset`: always compile directly (`limit`/
    `offset` are already validated `non_neg_integer() | nil` by
    `Scry.Core.Query.t()`'s own type, never externally-controlled
    strings, so they're rendered directly into the SQL text rather
    than bound as parameters).

  ## The real correctness subtlety this compiler exists to get right

  SQL's own `WHERE` (and aggregate functions) silently treat a `NULL`
  column value as "doesn't match"/"skip this value" -- a three-valued
  logic with no way to *raise* the way `Scry.Core.QueryOps.
  eval_predicate/4`'s own null-safety hard error does. Pushing a
  `WHERE age > 18` straight into SQL for a column that might genuinely
  be `NULL` would silently exclude that row instead of raising the
  error lang_spec.md §7 requires -- the same class of bug `Scry.
  Engine.ETS.MatchSpec` was built to avoid for ETS's own match-spec
  guards, except SQL genuinely has no per-row escape hatch to defer
  to (there's no downstream toolkit re-check left once a native
  aggregate has already collapsed rows away, or once `LIMIT`/`OFFSET`
  have already been applied against a `WHERE`-narrowed set). `compile/2`
  therefore also returns the set of columns that need a schema-level
  `NOT NULL` guarantee before the compiled SQL can be trusted --
  every column compared against a non-`nil` literal anywhere in
  `wheres` (the `field = nil`/`field != nil` null-check idiom itself
  is exempt, since SQL's own `IS NULL`/`IS NOT NULL` there already
  means exactly what the interpreter means), plus every aggregated
  column for an aggregate-shaped query (`avg` included -- this
  increment relaxes *exactness*, per `scry_core`'s own relaxed
  guarantee, but not *null-skipping*, a separate concern SQL's
  `AVG()` has exactly the same silent-skip behavior for as `SUM`/
  `COUNT(col)`/`MIN`/`MAX`). `Scry.Engine.Exqlite.execute/3` is the
  one that actually checks this (a real `PRAGMA table_info` query, so
  it needs the open connection this module doesn't have) inside the
  same transaction as the compiled query itself.

  One narrower, deliberately accepted gap: `ORDER BY` on a nullable
  column doesn't get this same protection -- SQLite sorts `NULL`
  first (ascending) or last (descending), which can genuinely differ
  from `Scry.Core.QueryOps.term_order/2`'s own raw-Erlang-term
  ordering for a bare `nil`. This only affects the *relative order* of
  null-valued rows among themselves, never which rows are silently
  dropped or which comparison silently fails to raise, so it's
  accepted as a documented, lower-stakes divergence rather than
  extended the same `NOT NULL`-gating treatment.

  ## A second correctness subtlety, found by property testing, not assumed

  `<`/`>`/`<=`/`>=` order values *differently* in SQLite than in
  `Scry.Core.QueryOps.term_order/2` when a column's own declared type
  doesn't match the compared literal's type -- confirmed directly: a
  `TEXT`-affinity column compared against an integer literal via `<`
  can disagree between the two (SQLite's own type-affinity rules
  govern the comparison, not Erlang's total term order, which always
  sorts a number below any binary/string). `:eq`/`:not_eq` don't have
  this problem (both systems already agree a string and a number are
  never equal), so `compile/2` also returns `type_checks` -- one
  `{column, :numeric | :text}` pair per *ordering* comparison's own
  field, the type inferred from the compared literal -- for `Scry.
  Engine.Exqlite.execute/3` to verify against the column's own real
  SQLite type affinity (the same `PRAGMA table_info` pass the `NOT
  NULL` check already makes) before trusting the compiled SQL's
  ordering to agree with the interpreter's own.
  """

  alias Scry.Core.Query
  alias Scry.Engine.Exqlite.WhereTranslator

  @aggregate_names ~w(sum avg count min max)
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @typedoc "A compiled statement, ready to prepare/bind/execute once any `not_null_columns`/`type_checks` check passes."
  @type compiled :: %{
          sql: String.t(),
          bind_params: [term()],
          not_null_columns: [String.t()],
          type_checks: [{String.t(), :numeric | :text}]
        }

  @spec compile(Query.t(), map()) :: {:ok, compiled()} | {:error, {:unsupported, term()}}
  def compile(%Query{} = query, params) do
    with {:ok, table} <- table_name(query.source),
         {:ok, where_sql, where_params} <- where_clause(query.wheres, params) do
      if aggregate_query?(query) do
        compile_aggregate(query, table, where_sql, where_params, params)
      else
        compile_plain(query, table, where_sql, where_params, params)
      end
    end
  end

  defp where_clause(wheres, params) do
    case WhereTranslator.translate(wheres, params) do
      {:ok, sql, bound} -> {:ok, sql, bound}
      :error -> {:error, {:unsupported, {:predicate, :untranslatable}}}
    end
  end

  defp table_name([table]) when is_binary(table) do
    if Regex.match?(@identifier, table),
      do: {:ok, table},
      else: {:error, {:unsupported, {:source, table}}}
  end

  defp table_name(source), do: {:error, {:unsupported, {:source, source}}}

  # ---- plain (non-aggregate) queries --------------------------------------

  defp compile_plain(query, table, where_sql, where_params, params) do
    with {:ok, select_sql} <- plain_select_list(query.select),
         {:ok, order_sql} <- order_by_clause(query.order_bys) do
      distinct_sql = if query.distinct, do: "DISTINCT ", else: ""
      limit_sql = limit_offset_clause(query.limit, query.offset)

      sql =
        "SELECT " <>
          distinct_sql <> select_sql <> " FROM " <> table <> where_sql <> order_sql <> limit_sql

      not_null_columns = not_null_columns_from_where(query.wheres)
      type_checks = type_checks_from_where(query.wheres, params)

      {:ok,
       %{
         sql: sql,
         bind_params: where_params,
         not_null_columns: not_null_columns,
         type_checks: type_checks
       }}
    end
  end

  defp plain_select_list([]), do: {:error, {:unsupported, {:select, :empty}}}

  defp plain_select_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case plain_select_item(item) do
        {:ok, sql} -> {:cont, {:ok, [sql | acc]}}
        :error -> {:halt, {:error, {:unsupported, {:select, item}}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.join(Enum.reverse(reversed), ", ")}
      error -> error
    end
  end

  defp plain_select_item({:field, [field]}) do
    if WhereTranslator.identifier?(field) do
      {:ok, "#{field} AS #{quote_ident(field)}"}
    else
      :error
    end
  end

  # A bare field under a caller-given alias (e.g. `Scry.Core.Query.
  # from/2`'s map-shaped `select:` always wraps every entry, even a
  # plain field reference, in `{:computed, alias, ...}}`) -- still just
  # `column AS alias`, no cast/arithmetic/function call involved.
  defp plain_select_item({:computed, alias_name, {:field, [field]}}) do
    if WhereTranslator.identifier?(field) do
      {:ok, "#{field} AS #{quote_ident(alias_name)}"}
    else
      :error
    end
  end

  defp plain_select_item(_other), do: :error

  # ---- aggregate-shaped queries --------------------------------------------

  defp aggregate_query?(query),
    do: query.group_bys != [] or Enum.any?(query.select, &aggregate_body_item?/1)

  defp aggregate_body_item?({:computed, _alias, {:call, name, _args}}),
    do: name in @aggregate_names

  defp aggregate_body_item?(_other), do: false

  defp compile_aggregate(query, table, where_sql, where_params, params) do
    with :ok <- check(query.group_mode == :plain, {:construct, query.group_mode}),
         :ok <- check(query.havings == [], {:construct, :having}),
         {:ok, group_by_cols} <- group_by_columns(query.group_bys),
         {:ok, select_items} <- aggregate_select_list(query.select, group_by_cols) do
      select_sql = Enum.map_join(select_items, ", ", & &1.sql)
      group_by_sql = group_by_clause(group_by_cols)
      sql = "SELECT " <> select_sql <> " FROM " <> table <> where_sql <> group_by_sql

      not_null_columns =
        (not_null_columns_from_where(query.wheres) ++ Enum.flat_map(select_items, & &1.not_null))
        |> Enum.uniq()

      type_checks = type_checks_from_where(query.wheres, params)

      {:ok,
       %{
         sql: sql,
         bind_params: where_params,
         not_null_columns: not_null_columns,
         type_checks: type_checks
       }}
    end
  end

  defp check(true, _detail), do: :ok
  defp check(false, detail), do: {:error, {:unsupported, detail}}

  defp group_by_columns(group_bys) do
    columns = Enum.map(group_bys, &hd/1)

    if Enum.all?(columns, &WhereTranslator.identifier?/1) do
      {:ok, columns}
    else
      {:error, {:unsupported, {:group_by, group_bys}}}
    end
  end

  defp group_by_clause([]), do: ""
  defp group_by_clause(columns), do: " GROUP BY " <> Enum.join(columns, ", ")

  defp aggregate_select_list(items, group_by_cols) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case aggregate_select_item(item, group_by_cols) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | acc]}}
        :error -> {:halt, {:error, {:unsupported, {:select, item}}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # A bare field is only ever valid here when it's exactly one of
  # `group_bys` -- there is no "representative row" to fall back on
  # for a non-grouped field once SQL has aggregated rows away, the
  # same reasoning `Scry.Core.QueryOps`'s own eager-aggregation path
  # relies on for its representative-row semantics not applying here.
  defp aggregate_select_item({:field, [field]}, group_by_cols) do
    if field in group_by_cols do
      {:ok, %{sql: "#{field} AS #{quote_ident(field)}", not_null: []}}
    else
      :error
    end
  end

  # The same bare-`GROUP BY`-column case as above, just under the
  # alias a caller (e.g. `Scry.Core.Query.from/2`'s map-shaped
  # `select:`) gave it explicitly, rather than the query's own field
  # name -- `{:computed, alias, {:field, [field]}}` compiles to the
  # exact same "no representative row" reasoning applies here.
  defp aggregate_select_item({:computed, alias_name, {:field, [field]}}, group_by_cols) do
    if field in group_by_cols do
      {:ok, %{sql: "#{field} AS #{quote_ident(alias_name)}", not_null: []}}
    else
      :error
    end
  end

  defp aggregate_select_item(
         {:computed, alias_name, {:call, "count", [{:distinct, {:field, [column]}}]}},
         _group_by_cols
       ) do
    if WhereTranslator.identifier?(column) do
      {:ok, %{sql: "COUNT(DISTINCT #{column}) AS #{quote_ident(alias_name)}", not_null: [column]}}
    else
      :error
    end
  end

  defp aggregate_select_item(
         {:computed, alias_name, {:call, name, [{:field, [column]}]}},
         _group_by_cols
       )
       when name in @aggregate_names do
    if WhereTranslator.identifier?(column) do
      {:ok,
       %{
         sql: "#{sql_function(name)}(#{column}) AS #{quote_ident(alias_name)}",
         not_null: [column]
       }}
    else
      :error
    end
  end

  defp aggregate_select_item(_other, _group_by_cols), do: :error

  defp sql_function("sum"), do: "SUM"
  defp sql_function("avg"), do: "AVG"
  defp sql_function("count"), do: "COUNT"
  defp sql_function("min"), do: "MIN"
  defp sql_function("max"), do: "MAX"

  # ---- ORDER BY / LIMIT / OFFSET -------------------------------------------

  defp order_by_clause([]), do: {:ok, ""}

  defp order_by_clause(order_bys) do
    order_bys
    |> Enum.reduce_while({:ok, []}, fn {path, direction}, {:ok, acc} ->
      case order_by_item(path, direction) do
        {:ok, sql} -> {:cont, {:ok, [sql | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, " ORDER BY " <> Enum.join(Enum.reverse(reversed), ", ")}
      :error -> {:error, {:unsupported, {:order_by, order_bys}}}
    end
  end

  defp order_by_item([field], direction) when direction in [:asc, :desc] do
    if WhereTranslator.identifier?(field) do
      {:ok, "#{field} #{if direction == :asc, do: "ASC", else: "DESC"}"}
    else
      :error
    end
  end

  defp order_by_item(_path, _direction), do: :error

  defp limit_offset_clause(nil, nil), do: ""
  defp limit_offset_clause(limit, nil) when is_integer(limit), do: " LIMIT #{limit}"
  defp limit_offset_clause(nil, offset) when is_integer(offset), do: " LIMIT -1 OFFSET #{offset}"

  defp limit_offset_clause(limit, offset) when is_integer(limit) and is_integer(offset),
    do: " LIMIT #{limit} OFFSET #{offset}"

  # ---- NOT NULL column collection (WHERE side) ----------------------------

  defp not_null_columns_from_where(wheres),
    do: wheres |> Enum.flat_map(&collect_not_null/1) |> Enum.uniq()

  defp collect_not_null({:cmp, op, [_field], nil}) when op in [:eq, :not_eq], do: []
  defp collect_not_null({:cmp, _op, [field], _value}), do: [field]
  defp collect_not_null({:in, _lhs, _values}), do: []
  defp collect_not_null({:and, l, r}), do: collect_not_null(l) ++ collect_not_null(r)
  defp collect_not_null({:or, l, r}), do: collect_not_null(l) ++ collect_not_null(r)
  defp collect_not_null({:not, p}), do: collect_not_null(p)
  defp collect_not_null(_other), do: []

  # ---- ordering type-affinity checks (WHERE side) -------------------------

  # Only `<`/`>`/`<=`/`>=` need this -- `=`/`!=` already agree between
  # SQLite and `Scry.Core.QueryOps.term_order/2` for a genuinely
  # mismatched type (neither ever considers a string and a number
  # equal), confirmed directly, not assumed from the ordering-operator
  # finding alone.
  defp type_checks_from_where(wheres, params),
    do: wheres |> Enum.flat_map(&collect_type_check(&1, params)) |> Enum.uniq()

  defp collect_type_check({:cmp, op, [field], value}, params) when op in [:lt, :gt, :le, :ge] do
    case resolve_type_class(value, params) do
      nil -> []
      class -> [{field, class}]
    end
  end

  defp collect_type_check({:and, l, r}, params),
    do: collect_type_check(l, params) ++ collect_type_check(r, params)

  defp collect_type_check({:or, l, r}, params),
    do: collect_type_check(l, params) ++ collect_type_check(r, params)

  defp collect_type_check({:not, p}, params), do: collect_type_check(p, params)
  defp collect_type_check(_other, _params), do: []

  defp resolve_type_class({:param, name}, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> value_type_class(value)
      :error -> nil
    end
  end

  defp resolve_type_class(value, _params), do: value_type_class(value)

  defp value_type_class(v) when is_binary(v), do: :text
  defp value_type_class(v) when is_number(v), do: :numeric
  defp value_type_class(_v), do: nil

  # ---- identifier quoting for output aliases -------------------------------

  # Unlike a *column reference* (validated against `@identifier` and
  # never quoted, since it must be a real, safe-to-interpolate SQL
  # name), a select item's own output alias can be any string a query
  # author chose (`{:computed, alias, ...}`'s own `alias`) -- standard
  # SQL double-quote identifier quoting (doubling an embedded `"`)
  # handles that safely without restricting aliases to the identifier
  # pattern real column names need.
  defp quote_ident(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
end
