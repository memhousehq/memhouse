# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Provider do
  @moduledoc """
  The behaviour every model backend implements — the single seam between
  MemHouse and anything that runs a model.

  Four callbacks cover structured output, chat, embedding, and reranking. Replacing one module
  therefore swaps the whole provider boundary.

  ## Implementing one

  - Return `{:ok, %Result{}}` or `{:error, reason}`. Raising is tolerated — the
    gateway converts an exception into an error — but returning is clearer.
  - A capability a backend genuinely cannot serve returns a descriptive error
    atom rather than pretending. An embedding-only backend should fail a chat
    call loudly, not return empty text.
  - Fill `usage` with whatever token counts the backend reports, so the ledger
    is accurate. Leave it empty rather than guessing.
  - Keep `metadata` free of content. It is filtered against an allowlist before
    it is stored, so anything unexpected is dropped anyway, but content must not
    be put there in the first place.

  ## Calling one

  Only `MemHouse.Model.Gateway` may invoke callbacks. Direct calls skip role resolution, tracing,
  and metering.
  """

  alias MemHouse.Model.Config.Role

  defmodule Result do
    @moduledoc """
    Provider value, usage, and content-safe metadata.

    `:value` is capability-specific — a decoded object for structured
    generation, a string for chat, a list of vectors for embedding, a ranked
    list for reranking.

    `:usage` holds token counts (`:input_tokens`, `:output_tokens`,
    `:embedding_tokens`) as reported by the backend. Missing keys are treated as
    zero; do not invent numbers to fill it.

    `:metadata` is small, content-free annotation such as the model name the
    backend actually served, a result count, or a flag that the offline
    stand-in produced this. It is reduced to a fixed allowlist before being
    stored, so it must never be used to smuggle prompt or completion text.
    """
    @type t :: %__MODULE__{value: term(), usage: map(), metadata: map()}
    defstruct [:value, usage: %{}, metadata: %{}]
  end

  @doc """
  Generates one object against a JSON schema. The third argument is an
  already-built schema map. Constrain decoding with it when the backend can;
  either way the result is validated again by the caller, so returning
  approximately-correct output is a bug worth failing on rather than smoothing
  over.
  """
  @callback structured(Role.t(), [map()], map(), keyword()) ::
              {:ok, Result.t()} | {:error, term()}

  @doc """
  Generates free text from a message list. `:value` is the completion string.
  """
  @callback chat(Role.t(), [map()], keyword()) :: {:ok, Result.t()} | {:error, term()}

  @doc """
  Embeds a list of texts. `:value` must be a list of float lists, one per input
  and in input order, each exactly the width pinned on the role — the caller
  rejects any other width rather than adapting to it.
  """
  @callback embed(Role.t(), [String.t()], keyword()) ::
              {:ok, Result.t()} | {:error, term()}

  @doc """
  Reorders documents by relevance to a query. `:value` is the backend's own
  ranked-result shape.
  """
  @callback rerank(Role.t(), String.t(), [String.t()], keyword()) ::
              {:ok, Result.t()} | {:error, term()}
end
