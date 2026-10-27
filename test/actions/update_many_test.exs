# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Actions.UpdateManyTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Ash.Test.Domain, as: Domain

  defmodule RecordingDataLayer do
    @moduledoc false
    @behaviour Ash.DataLayer
    use Spark.Dsl.Extension, transformers: [], sections: []

    @impl true
    def can?(_, feature)
        when feature in [
               :update_many,
               :update,
               :filter,
               :changeset_filter,
               :boolean_filter,
               :nested_expressions
             ],
        do: true

    def can?(_, {:atomic, :update}), do: true
    def can?(_, {:filter_expr, _}), do: true
    def can?(_, _), do: false

    @impl true
    def resource_to_query(resource, domain), do: %{resource: resource, domain: domain}

    @impl true
    def update_many(_resource, changesets, _opts) do
      changesets = Enum.to_list(changesets)
      send(self(), {:update_many, changesets})

      {:ok,
       Enum.map(changesets, fn changeset ->
         {:ok, record} = Ash.Changeset.apply_attributes(changeset)
         record
       end)}
    end
  end

  defmodule ReportAttributes do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def atomic(changeset, _opts, _context), do: {:ok, changeset}

    @impl true
    def batch_change(changesets, _opts, _context), do: changesets

    @impl true
    def after_batch(changesets_and_results, _opts, _context) do
      Enum.map(changesets_and_results, fn {changeset, result} ->
        send(self(), {:after_batch, result.id, changeset.attributes})
        {:ok, result}
      end)
    end
  end

  defmodule Stop do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: RecordingDataLayer

    actions do
      defaults [:read]

      update :update do
        primary? true
        accept [:at, :name, :count]
      end

      update :report do
        accept [:at, :name, :count]
        change ReportAttributes
      end
    end

    attributes do
      attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
      attribute :at, :utc_datetime_usec, allow_nil?: false, public?: true
      attribute :name, :string, public?: true
      attribute :count, :integer, public?: true, constraints: [min: 0]
    end
  end

  defp stops(count) do
    for id <- 1..count do
      struct(Stop, id: id, at: ~U[2026-01-01 00:00:00.000000Z], name: "old", count: 0)
    end
  end

  defp inputs(stops) do
    Enum.map(stops, fn stop ->
      {stop,
       %{
         at: DateTime.add(~U[2026-01-01 00:00:00.000000Z], stop.id * 60),
         name: "stop #{stop.id}",
         count: stop.id
       }}
    end)
  end

  test "rows that differ only in literal values are written in one statement" do
    result =
      3
      |> stops()
      |> inputs()
      |> Ash.update_many(Stop, :update, return_records?: true, return_errors?: true)

    assert result.status == :success
    assert_receive {:update_many, changesets}
    refute_receive {:update_many, _}

    assert length(changesets) == 3

    for %{id: id} = record <- result.records do
      assert record.at == DateTime.add(~U[2026-01-01 00:00:00.000000Z], id * 60)
      assert record.name == "stop #{id}"
      assert record.count == id
    end
  end

  test "literal values are cast and constrained before they are written" do
    [stop] = stops(1)

    result =
      Ash.update_many(
        [{stop, %{at: "2026-02-03T04:05:06.000007Z", count: "4"}}],
        Stop,
        :update,
        return_records?: true,
        return_errors?: true
      )

    assert result.status == :success
    assert [%{at: ~U[2026-02-03 04:05:06.000007Z], count: 4}] = result.records

    result =
      Ash.update_many([{stop, %{count: -1}}], Stop, :update, return_errors?: true)

    assert result.status == :error
  end

  test "after_batch hooks see each row's own changeset" do
    3
    |> stops()
    |> inputs()
    |> Ash.update_many(Stop, :report, return_errors?: true)

    for id <- 1..3 do
      assert_receive {:after_batch, ^id, %{name: name, count: ^id}}
      assert name == "stop #{id}"
    end
  end
end
