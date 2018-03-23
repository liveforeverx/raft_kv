use Croma

defmodule RaftKV.KeyspaceInfo do
  alias RaftKV.{Hash, SplitMergePolicy}

  use Croma.Struct, fields: [
    policy: SplitMergePolicy,
    shards: Croma.Tuple, # :gb_trees.tree(nil | :locked | last_split_merge_time, range_start, {n_keys, size, load})
  ]

  defun make(policy :: v[SplitMergePolicy.t]) :: v[t] do
    shards_with_1st = :gb_trees.insert(0, {nil, nil, nil, nil}, :gb_trees.empty())
    %__MODULE__{policy: policy, shards: shards_with_1st}
  end

  defun shard_range_start_positions(%__MODULE__{shards: shards}) :: [Hash.t] do
    :gb_trees.keys(shards)
  end

  defun add_shard(%__MODULE__{shards: shards} = info, new_range_start :: v[Hash.t]) :: v[t] do
    new_shards = :gb_trees.insert(new_range_start, {:locked, nil, nil, nil}, shards)
    %__MODULE__{info | shards: new_shards}
  end

  defun touch_both(%__MODULE__{shards: shards} = info, range_start1 :: v[Hash.t], range_start2 :: v[Hash.t], time :: v[pos_integer]) :: v[t] do
    new_shards = shards |> touch1(range_start1, time) |> touch1(range_start2, time)
    %__MODULE__{info | shards: new_shards}
  end

  defun touch_and_delete(%__MODULE__{shards: shards} = info,
                         range_start1 :: v[Hash.t],
                         range_start2 :: v[Hash.t],
                         time         :: v[pos_integer]) :: v[t] do
    new_shards = :gb_trees.delete(range_start2, shards) |> touch1(range_start1, time)
    %__MODULE__{info | shards: new_shards}
  end

  defp touch1(shards, range_start, time) do
    {_t, n, s, l} = :gb_trees.get(range_start, shards)
    :gb_trees.update(range_start, {time, n, s, l}, shards)
  end

  @typep pair_or_nil :: nil | {non_neg_integer, non_neg_integer}

  defun store(%__MODULE__{policy: %SplitMergePolicy{load_per_query_to_missing_key: load_per_knf} = policy,
                          shards: shards} = info,
              map            :: %{Hash.t => {pair_or_nil, pair_or_nil}},
              threshold_time :: v[pos_integer]) :: {t, [{float, Hash.t}], [{float, Hash.t, Hash.t}]} do
    {new_shards, split_candidates, merge_candidates} =
      Enum.reduce(map, {shards, [], []}, fn({range_start, pair_of_pairs}, {r1, scs1, mcs1}) ->
        debug_assert(pair_of_pairs != {nil, nil})
        case get_quad_and_update_shard(r1, load_per_knf, range_start, pair_of_pairs) do
          nil ->
            {r1, scs1, mcs1}
          {r2, quad} ->
            {scs2, mcs2} =
              case compute_split_merge_demand(policy, r2, threshold_time, range_start, quad) do
                nil          -> {scs1       , mcs1       }
                {:split, sc} -> {[sc | scs1], mcs1       }
                {:merge, mc} -> {scs1       , [mc | mcs1]}
              end
            {r2, scs2, mcs2}
        end
      end)
    {%__MODULE__{info | shards: new_shards}, split_candidates, merge_candidates}
  end

  defp get_quad_and_update_shard(shards, load_per_knf, range_start, pair_of_pairs) do
    case :gb_trees.lookup(range_start, shards) do
      :none ->
        nil
      {:value, {t, _n, _s, _l}} ->
        {n, s, l} =
          case pair_of_pairs do
            {{n_keys, size}, nil        } -> {n_keys, size, nil                      }
            {nil           , {load, knf}} -> {nil   , nil , load + load_per_knf * knf}
            {{n_keys, size}, {load, knf}} -> {n_keys, size, load + load_per_knf * knf}
          end
        q = {t, n, s, l}
        {:gb_trees.update(range_start, q, shards), q}
    end
  end

  defp compute_split_merge_demand(%SplitMergePolicy{max_keys_per_shard:    max_keys,
                                                    max_size_per_shard:    max_size,
                                                    max_load_per_shard:    max_load,
                                                    merge_threshold_ratio: merge_threshold_ratio},
                                  shards,
                                  threshold_time,
                                  range_start,
                                  {last_split_merge_time, n_keys, size, load}) do
    if max_keys || max_size || max_load do # at least 1 limit must be specified to perform split/merge
      if n_keys do
        debug_assert(size) # `size` should also be filled when `n_keys` is filled.
        stats = {n_keys, size, load || 0} # If `load` is not filled (even though `n_keys` is filled), treat this as "no load".
        if eligible_for_split_or_merge?(last_split_merge_time, threshold_time) do
          limits = {max_keys, max_size, max_load}
          case calc_max_ratio(stats, limits) do
            max_ratio when max_ratio > 1.0 and n_keys > 1    -> {:split, {max_ratio, range_start}} # Don't split shard with `n_keys == 1`, as (probably) splitting won't help in that case.
            max_ratio when max_ratio < merge_threshold_ratio -> compute_merge_demand(shards, threshold_time, range_start, merge_threshold_ratio, stats, limits)
            _otherwise                                       -> nil
          end
        end
      end
    end
  end

  defp compute_merge_demand(shards, threshold_time, range_start, merge_threshold_ratio, {n_keys, size, load}, limits) do
    case tree_next(shards, range_start) do
      {next_range_start, {last_split_merge_time2, n_keys2, size2, load2}} when is_integer(n_keys2) ->
        debug_assert(size2) # `size2` should also be filled when `n_keys2` is filled.
        load2 = load2 || 0 # If `load2` is not filled (even though `n_keys2` is filled), treat this as "no load".
        if eligible_for_split_or_merge?(last_split_merge_time2, threshold_time) do
          max_ratio_when_merged = calc_max_ratio({n_keys + n_keys2, size + size2, load + load2}, limits)
          if max_ratio_when_merged < merge_threshold_ratio do
            {:merge, {max_ratio_when_merged, range_start, next_range_start}}
          end
        end
      _no_next_or_n_keys2_is_nil ->
        nil
    end
  end

  defp calc_max_ratio({n_keys, size, load}, {max_keys, max_size, max_load}) do
    [
      {n_keys, max_keys},
      {size  , max_size},
      {load  , max_load},
    ]
    |> Enum.reject(&match?({_, nil}, &1))
    |> Enum.map(fn {value, limit} -> value / limit end)
    |> Enum.max() # should not fail as at least 1 limit is non-nil
  end

  defp eligible_for_split_or_merge?(nil                  , _t            ), do: true
  defp eligible_for_split_or_merge?(:locked              , _t            ), do: false
  defp eligible_for_split_or_merge?(last_split_merge_time, threshold_time), do: last_split_merge_time < threshold_time

  defun check_if_splittable(%__MODULE__{policy: %SplitMergePolicy{max_shards: max_shards},
                                        shards: shards} = info,
                            range_start :: v[Hash.t]) :: {:ok, t, Hash.t} | :error do
    if :gb_trees.size(shards) < max_shards do
      case :gb_trees.lookup(range_start, shards) do
        :none ->
          :error
        {:value, {_t, n, s, l}} ->
          new_shards = :gb_trees.update(range_start, {:locked, n, s, l}, shards)
          new_info = %__MODULE__{info | shards: new_shards}
          range_end =
            case tree_next(shards, range_start) do
              nil            -> Hash.upper_bound()
              {r_end, _quad} -> r_end
            end
          {:ok, new_info, div(range_start + range_end, 2)}
      end
    else
      :error
    end
  end

  defun check_if_mergeable(%__MODULE__{policy: %SplitMergePolicy{min_shards: min_shards},
                                       shards: shards} = info,
                           range_start1 :: v[Hash.t],
                           range_start2 :: v[Hash.t]) :: {:ok, t} | :error do
    if :gb_trees.size(shards) > min_shards do
      case {:gb_trees.lookup(range_start1, shards), :gb_trees.lookup(range_start2, shards)} do
        {:none                      , _                          } -> :error
        {_                          , :none                      } -> :error
        {{:value, {_t1, n1, s1, l1}}, {:value, {_t2, n2, s2, l2}}} ->
          new_shards1 = :gb_trees.update(range_start1, {:locked, n1, s1, l1}, shards)
          new_shards2 = :gb_trees.update(range_start2, {:locked, n2, s2, l2}, new_shards1)
          new_info = %__MODULE__{info | shards: new_shards2}
          {:ok, new_info}
      end
    else
      :error
    end
  end

  defp tree_next(shards, range_start) do
    case :gb_trees.iterator_from(range_start + 1, shards) |> :gb_trees.next() do
      :none                     -> nil
      {next_start, quad, _iter} -> {next_start, quad}
    end
  end
end
