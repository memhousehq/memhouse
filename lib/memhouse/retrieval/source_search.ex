# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.SourceSearch do
  @moduledoc """
  Governed exact and semantic recall over immutable source messages.

  The caller supplies an authority tuple produced by `MemHouse.Memory`: an
  Account actor and an already-authorized scope list. Every SQL statement
  repeats those filters before ranking. Results contain stable citation data
  and a bounded excerpt, never the unbounded source body.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Model.Embedding
  alias MemHouse.Retrieval.DiskannLabels
  alias MemHouse.Retrieval.Store

  @default_limit 12
  @max_limit 100
  @default_excerpt_chars 480
  @max_excerpt_chars 2_000

  @type authority :: %{
          required(:account_id) => Ecto.UUID.t(),
          required(:actor) => MemHouse.Actor.t(),
          required(:scope_ids) => [Ecto.UUID.t()]
        }

  @doc """
  Searches only scopes already authorized by `MemHouse.Memory`.

  `:exact` is generated full-text search and performs no model call. `:semantic`
  embeds the query outside any database transaction, then compares only rows
  carrying the same four-part embedding identity. The returned status is one
  of `ready`, `stale`, `empty`, `unavailable`, or `failed` and never includes a
  hidden corpus count.
  """
  def search(authority, text, opts \\ []) when is_binary(text) do
    mode = normalize_mode(Keyword.get(opts, :mode, :semantic))
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit)

    excerpt_chars =
      opts
      |> Keyword.get(:excerpt_chars, @default_excerpt_chars)
      |> clamp(80, @max_excerpt_chars)

    started_at = System.monotonic_time(:millisecond)

    result =
      case {mode, String.trim(text)} do
        {_mode, ""} ->
          %{mode: mode, status: :empty, results: [], degraded: false, failure_class: nil}

        {:exact, text} ->
          exact(authority, text, limit, excerpt_chars)

        {:semantic, text} ->
          semantic(authority, text, limit, excerpt_chars)
      end

    latency_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:memhouse, :retrieval, :source_search],
      %{latency_ms: latency_ms, result_count: length(result.results)},
      %{mode: mode, status: result.status, failure_class: result.failure_class}
    )

    result
    |> Map.put(:latency_ms, latency_ms)
    |> stringify()
  end

  defp exact(authority, text, limit, excerpt_chars) do
    {rows, status} =
      in_account(authority, fn ->
        rows = Store.source_exact(authority, text, limit, excerpt_chars)
        status = if Store.source_visible?(authority), do: :ready, else: :empty
        {rows, status}
      end)

    %{mode: :exact, status: status, results: rank(rows), degraded: false, failure_class: nil}
  end

  defp semantic(authority, text, limit, excerpt_chars) do
    context = %{account_id: authority.account_id, actor: authority.actor}

    case Embedding.embed([text], context, input_type: :query) do
      {:ok, %{vectors: [vector]} = identity} ->
        {rows, status} =
          in_account(authority, fn ->
            labels = DiskannLabels.for_scope_ids!(authority.account_id, authority.scope_ids)

            rows =
              Store.source_semantic(authority, vector, identity, labels, limit, excerpt_chars)

            {rows, Store.source_embedding_status(authority, identity)}
          end)

        %{
          mode: :semantic,
          status: status,
          results: rank(rows),
          degraded: status in [:stale, :unavailable],
          failure_class: nil
        }

      {:error, error} ->
        %{
          mode: :semantic,
          status: :failed,
          results: [],
          degraded: true,
          failure_class: classify_error(error)
        }
    end
  end

  defp in_account(authority, fun) do
    DataLayer.with_actor(authority.actor, fn _account, _actor -> fun.() end)
  end

  defp rank(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} -> Map.put(row, "rank", rank) end)
  end

  defp normalize_mode(mode) when mode in [:exact, "exact"], do: :exact
  defp normalize_mode(mode) when mode in [:semantic, "semantic"], do: :semantic

  defp normalize_mode(mode),
    do: raise(ArgumentError, "unknown source search mode: #{inspect(mode)}")

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  defp classify_error({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp classify_error(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp classify_error(_), do: "provider_error"

  defp stringify(map) do
    Map.new(map, fn {key, value} ->
      value =
        if is_atom(value) and not is_boolean(value) and not is_nil(value),
          do: Atom.to_string(value),
          else: value

      {Atom.to_string(key), value}
    end)
  end
end
