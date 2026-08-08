# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Reasoner do
  @moduledoc """
  The background reasoning capability: re-reads recent knowledge and proposes
  deductions and relations.

  This slow lane revisits a delta and stored working set when budget allows.

  No production caller uses it; `dream_time` currently runs the governance sweeper.

  ## What it may and may not produce

  Reasoning proposes schema-validated candidates; governance decides. Contradictions return as
  typed relation edges and never overwrite statements.

  ## Mistakes to avoid

  - Do not treat a returned candidate as active knowledge. It has passed schema
    validation, nothing more.
  - Do not call this on a request path. It is the slow lane by design and its
    latency is not bounded by a caller's deadline.
  """

  alias MemHouse.Model
  alias MemHouse.Model.Schema.Reasoning

  # Names the prompt template below, and is passed to the gateway as a call
  # option. Note that the `prompt_version` actually stamped on provenance and
  # usage rows comes from the resolved `dream_reasoner` role, not from here; the
  # two are kept equal on purpose, so editing the prompt means bumping both.
  @prompt_version "reason-1"

  @doc """
  Runs one reasoning pass over a delta and its working set.

  `delta_and_working_set` is any JSON-encodable term describing what changed and
  the surrounding knowledge to reason over; it is serialized as the user turn.
  `context` is the caller context, and must carry the Account and scope so
  candidate subjects can be validated and usage attributed.

  Returns `{:ok, %{items: candidates, relations: edges}, provenance_map}`, or an
  error from structured generation — a validation failure after the repair
  budget, or a provider error. Errors are returned rather than raised, and
  nothing partial is applied.
  """
  def reason(delta_and_working_set, context, opts \\ []) do
    messages = [
      %{
        role: "system",
        content: """
        Revisit the supplied delta and working set. Return only supported
        deductions, update candidates, and supports/contradicts/derived_from
        relations in the supplied schema. Never overwrite contradictions.
        """
      },
      %{role: "user", content: Jason.encode!(delta_and_working_set)}
    ]

    Model.generate_structured(
      :dream_reasoner,
      messages,
      Reasoning,
      context,
      Keyword.merge([task: :reasoning, prompt_version: @prompt_version], opts)
    )
  end
end
