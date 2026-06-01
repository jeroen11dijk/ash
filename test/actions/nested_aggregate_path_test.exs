# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Actions.NestedAggregatePathTest do
  @moduledoc """
  Regression test for a crash when loading a *nested* aggregate whose *inner*
  aggregate spans a *multi-hop* relationship path.

  Relationship chain: A -> bs -> B -> cs -> C -> ds -> D

  Loading `:outer` raised, during aggregate authorization:

      ** (RuntimeError) Attempted to read relationship path that does not exist.
         Resource: D   Path: [:cs]

  The inner aggregate's path `[:cs, :ds]` is relative to its source `B`, but it
  was walked against `D` (the path's *target*). A single-hop inner path does not
  trigger it (there are no sub-paths to walk).
  """
  use ExUnit.Case, async: true

  require Ash.Query

  alias Ash.Test.Domain, as: Domain

  defmodule D do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
      attribute :c_id, :uuid
    end

    actions do
      defaults [:read]
    end
  end

  defmodule C do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
      attribute :b_id, :uuid
    end

    actions do
      defaults [:read]
    end

    relationships do
      has_many :ds, D, destination_attribute: :c_id
    end
  end

  defmodule B do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
      attribute :a_id, :uuid
    end

    actions do
      defaults [:read]
    end

    relationships do
      has_many :cs, C, destination_attribute: :b_id
    end

    aggregates do
      # multi-hop path, relative to B: B -> cs -> ds
      count :inner, [:cs, :ds]
    end
  end

  defmodule A do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end

    relationships do
      has_many :bs, B, destination_attribute: :a_id
    end

    aggregates do
      # nested aggregate: sums B's `inner` count over A's bs
      sum :outer, :bs, :inner
    end
  end

  test "loading a nested aggregate over a multi-hop inner aggregate does not crash" do
    assert [] = A |> Ash.Query.load(:outer) |> Ash.read!()
  end
end
