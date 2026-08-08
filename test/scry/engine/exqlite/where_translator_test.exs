defmodule Scry.Engine.Exqlite.WhereTranslatorTest do
  @moduledoc """
  `Scry.Engine.Exqlite.WhereTranslator` -- confirms exactly which
  predicate shapes translate into real SQL (every `:cmp` op but
  `:match`, `:in`, a full recursive `:and`/`:or`/`:not` tree, a
  single-segment identifier-safe field, a plain string/integer/float
  value or a `{:param, name}` resolved against `params`, the literal
  `nil` null-check idiom translating to `IS NULL`/`IS NOT NULL`) and
  which are declined -- all-or-nothing, unlike the old, lenient
  `fetch/3`-era translator this replaces: a single untranslatable leaf
  anywhere in the tree declines the *entire* translation, never a
  partial clause silently narrowing what SQLite returns. A property
  test proves the translator never raises and always binds exactly
  one param per `?` placeholder whenever it succeeds, across an
  arbitrary predicate list.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Engine.Exqlite.WhereTranslator

  describe "translatable shapes" do
    test "an empty wheres list produces no clause at all" do
      assert WhereTranslator.translate([], %{}) == {:ok, "", []}
    end

    test "every supported comparison operator translates" do
      for {op, sql_op} <- [eq: "=", not_eq: "!=", lt: "<", gt: ">", le: "<=", ge: ">="] do
        assert WhereTranslator.translate([{:cmp, op, ["age"], 18}], %{}) ==
                 {:ok, " WHERE age #{sql_op} ?", [18]}
      end
    end

    test "string, integer, and float values are all translatable" do
      assert WhereTranslator.translate([{:cmp, :eq, ["name"], "Alice"}], %{}) ==
               {:ok, " WHERE name = ?", ["Alice"]}

      assert WhereTranslator.translate([{:cmp, :eq, ["age"], 30}], %{}) ==
               {:ok, " WHERE age = ?", [30]}

      assert WhereTranslator.translate([{:cmp, :ge, ["score"], 1.5}], %{}) ==
               {:ok, " WHERE score >= ?", [1.5]}
    end

    test "a DateTime/NaiveDateTime literal translates, bound as its own epoch-microseconds integer" do
      datetime = ~U[2026-01-01 00:00:00Z]
      naive = ~N[2026-01-01 00:00:00]

      assert WhereTranslator.translate([{:cmp, :ge, ["timestamp"], datetime}], %{}) ==
               {:ok, " WHERE timestamp >= ?", [DateTime.to_unix(datetime, :microsecond)]}

      assert WhereTranslator.translate([{:cmp, :ge, ["timestamp"], naive}], %{}) ==
               {:ok, " WHERE timestamp >= ?",
                [NaiveDateTime.diff(naive, ~N[1970-01-01 00:00:00], :microsecond)]}
    end

    test "multiple wheres entries are AND-joined, in order" do
      wheres = [{:cmp, :eq, ["status"], "active"}, {:cmp, :gt, ["age"], 18}]

      assert WhereTranslator.translate(wheres, %{}) ==
               {:ok, " WHERE status = ? AND age > ?", ["active", 18]}
    end

    test "a {:and, ...}/{:or, ...}/{:not, ...} tree translates recursively, each combinator parenthesized" do
      wheres = [
        {:or, {:and, {:cmp, :eq, ["id"], 1}, {:cmp, :eq, ["status"], "active"}},
         {:not, {:cmp, :eq, ["id"], 2}}}
      ]

      assert WhereTranslator.translate(wheres, %{}) ==
               {:ok, " WHERE ((id = ? AND status = ?) OR NOT (id = ?))", [1, "active", 2]}
    end

    test "a {:param, name} resolves against params and binds like a literal" do
      wheres = [{:cmp, :eq, ["tenant_id"], {:param, "tenant"}}]

      assert WhereTranslator.translate(wheres, %{"tenant" => 42}) ==
               {:ok, " WHERE tenant_id = ?", [42]}
    end

    test "field = nil / field != nil translate to IS NULL / IS NOT NULL, not a bound NULL" do
      assert WhereTranslator.translate([{:cmp, :eq, ["deleted_at"], nil}], %{}) ==
               {:ok, " WHERE deleted_at IS NULL", []}

      assert WhereTranslator.translate([{:cmp, :not_eq, ["deleted_at"], nil}], %{}) ==
               {:ok, " WHERE deleted_at IS NOT NULL", []}
    end

    test "an :in predicate with a literal list translates to a real SQL IN (...)" do
      assert WhereTranslator.translate([{:in, ["status"], ["active", "pending"]}], %{}) ==
               {:ok, " WHERE status IN (?, ?)", ["active", "pending"]}
    end

    test "an :in predicate whose own list contains a resolvable {:param, name} still translates" do
      assert WhereTranslator.translate([{:in, ["status"], [{:param, "s"}]}], %{"s" => "active"}) ==
               {:ok, " WHERE status IN (?)", ["active"]}
    end
  end

  describe "predicates that decline the whole translation" do
    test ":match has no direct SQL equivalent" do
      assert WhereTranslator.translate([{:cmp, :match, ["name"], "Ali.*"}], %{}) == :error
    end

    test "a multi-segment field path declines" do
      assert WhereTranslator.translate([{:cmp, :eq, ["metadata", "color"], "red"}], %{}) == :error
    end

    test "a field that isn't a safe SQL identifier declines" do
      assert WhereTranslator.translate([{:cmp, :eq, ["bad; DROP TABLE users;--"], 1}], %{}) ==
               :error
    end

    test "a boolean value declines (ambiguous SQLite storage encoding)" do
      assert WhereTranslator.translate([{:cmp, :eq, ["active"], true}], %{}) == :error
    end

    test "a {:field, ...} right-hand side declines (correlation is orchestration's job, not this module's)" do
      assert WhereTranslator.translate([{:cmp, :eq, ["age"], {:field, ["min_age"]}}], %{}) ==
               :error
    end

    test "a missing param resolution declines the whole translation" do
      assert WhereTranslator.translate([{:cmp, :eq, ["tenant_id"], {:param, "tenant"}}], %{}) ==
               :error
    end

    test "a param resolving to a non-literal (e.g. a list) declines" do
      wheres = [{:cmp, :eq, ["tenant_id"], {:param, "tenant"}}]
      assert WhereTranslator.translate(wheres, %{"tenant" => [1, 2]}) == :error
    end

    test "an :in against a non-literal-list expr declines (no JSON table function attempted)" do
      assert WhereTranslator.translate([{:in, ["status"], {:field, ["tags"]}}], %{}) == :error
    end

    test "a single untranslatable predicate anywhere in the tree declines the WHOLE translation, no partial clause" do
      wheres = [
        {:cmp, :eq, ["status"], "active"},
        {:cmp, :match, ["name"], "Ali.*"}
      ]

      assert WhereTranslator.translate(wheres, %{}) == :error
    end

    test "an untranslatable leaf nested inside a translatable :or/:and still declines the whole thing" do
      assert WhereTranslator.translate(
               [{:or, {:cmp, :eq, ["id"], 1}, {:cmp, :match, ["name"], "x"}}],
               %{}
             ) ==
               :error
    end
  end

  property "whenever it succeeds, the placeholder count always matches the bound param count, and it never raises" do
    check all(wheres <- list_of(predicate_generator())) do
      case WhereTranslator.translate(wheres, %{"x" => 1}) do
        {:ok, sql, params} ->
          placeholder_count = sql |> String.graphemes() |> Enum.count(&(&1 == "?"))
          assert placeholder_count == length(params)

        :error ->
          :ok
      end
    end
  end

  defp predicate_generator do
    gen all(
          field <- field_generator(),
          op <- member_of([:eq, :not_eq, :lt, :gt, :le, :ge, :match]),
          value <- value_generator()
        ) do
      {:cmp, op, [field], value}
    end
  end

  defp field_generator do
    one_of([
      map(string(:alphanumeric, min_length: 1), &("f_" <> &1)),
      constant("not an identifier!")
    ])
  end

  defp value_generator do
    one_of([
      string(:printable),
      integer(),
      float(),
      constant(nil),
      boolean(),
      constant({:field, ["other"]}),
      constant({:param, "x"})
    ])
  end
end
