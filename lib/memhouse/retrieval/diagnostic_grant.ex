# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.DiagnosticGrant do
  @moduledoc """
  Permission token that unlocks retrieval's internal seam for one diagnostic run.

  Naming strategies, disabling the deadline, forcing reranking off, and asking
  retrieval to explain its ranking are internal knobs, not public contract.
  `MemHouse.Memory.search/2` honours them only when its filters carry this
  struct, and decoded JSON cannot produce a struct — so a request body arriving
  at the same facade can never forge one.

  Holding a grant confers no data access. The retrieval query still runs under
  the caller's Account, authorized scopes, lifecycle visibility, and subject
  rules; a grant only changes which strategies run and how long they may take.
  The rank trace it can request describes candidates the same run already
  returned, so it too discloses nothing new.

  Build one through `MemHouse.Memory.diagnostic_search/2`, which authorizes the
  actor first.
  """

  alias MemHouse.Retrieval.Profile

  # A diagnostic run exists to see past the ordinary result window, so the cap
  # has to be well above it, and it still has to bound the work one browser form
  # can ask a database for. Each strategy also contributes at most this many
  # rows, so raising it widens the whole pre-fusion pool.
  @max_limit 100

  @enforce_keys [:limit]
  defstruct [:limit, :strategies, rerank: nil, deadline?: true, trace?: false]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          strategies: [atom()] | nil,
          rerank: boolean() | nil,
          deadline?: boolean(),
          trace?: boolean()
        }

  @doc "Largest candidate limit a diagnostic run may request."
  def max_limit, do: @max_limit

  @doc """
  Builds a grant from already-authorized options.

  `opts` accepts `:limit`, `:strategies`, `:rerank`, `:deadline?`, and `:trace?`.
  The limit is clamped into `1..#{@max_limit}`; an unusable value falls back to
  `default_limit`. Strategy names are validated against the registry, and an
  empty or absent list becomes `nil`, meaning "use the resolved profile's own
  strategies". `:trace?` asks retrieval to explain the ranking it produced.

  Raises `ArgumentError` for an unregistered strategy name, because a silently
  dropped name would make the run misreport what it did.
  """
  def new(default_limit, opts \\ []) do
    %__MODULE__{
      limit: clamp_limit(Keyword.get(opts, :limit), default_limit),
      strategies: strategies(Keyword.get(opts, :strategies)),
      rerank: rerank(Keyword.get(opts, :rerank)),
      deadline?: Keyword.get(opts, :deadline?, true) != false,
      trace?: Keyword.get(opts, :trace?) in [true, "true", "on", "1"]
    }
  end

  @doc """
  Content-free description of what a grant asked for, with string keys.

  This is what the console exports as a reproducible request, so it must stay
  free of the caller's identity, credentials, and Account.
  """
  def to_map(%__MODULE__{} = grant) do
    %{
      "limit" => grant.limit,
      "strategies" => grant.strategies && Enum.map(grant.strategies, &Atom.to_string/1),
      "deadline" => if(grant.deadline?, do: "enabled", else: "disabled"),
      "rerank" => grant.rerank
    }
  end

  defp clamp_limit(value, default) do
    case parse_limit(value) do
      nil -> default
      limit -> limit |> max(1) |> min(@max_limit)
    end
  end

  defp parse_limit(value) when is_integer(value), do: value

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {limit, _rest} -> limit
      :error -> nil
    end
  end

  defp parse_limit(_value), do: nil

  # An empty selection is "no override", not "run nothing": a form that submits
  # no checkbox must fall back to the profile rather than produce an empty
  # result that reads like an absence of knowledge.
  defp strategies(nil), do: nil
  defp strategies([]), do: nil

  defp strategies(names) when is_list(names) do
    registered = Profile.strategy_names()

    Enum.map(names, fn name ->
      Enum.find(registered, &(Atom.to_string(&1) == to_string(name))) ||
        raise ArgumentError, "unknown retrieval strategy: #{inspect(name)}"
    end)
  end

  defp strategies(name), do: strategies([name])

  # `nil` keeps the profile's own setting; only an explicit boolean overrides it.
  defp rerank(value) when is_boolean(value), do: value
  defp rerank("true"), do: true
  defp rerank("false"), do: false
  defp rerank(_value), do: nil
end
