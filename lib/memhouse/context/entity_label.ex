# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.EntityLabel do
  @moduledoc """
  Derives an entity card's display label and kind from its own in-scope surface forms.

  A card may show a surface form because that form already appears in a statement the same card
  supplies. `Knowledge.Entity.canonical_name` and `Knowledge.Entity.kind` must never be used here:
  both are account-global, and `kind` is frozen at the first spelling ever seen, so either would
  report something coined in a scope the reader cannot access.

  Word matching is English-only. A deployment whose statements are in another language gets no
  label rather than a wrong one.
  """

  alias MemHouse.Retrieval.EntityResolver

  # Closed-class English words. A form that is one of these describes no referent, so it is never
  # a label. This is deliberately not a general stopword list: content words must survive, however
  # common.
  #
  # Matching is case-folded, because the spotter only ever emits a capitalised form and a
  # case-sensitive list of lowercase words would match nothing. That forces a choice on words that
  # are also names: `will` and `may` are left out entirely, since deleting the label of someone
  # called Will costs more than keeping a modal verb that no card is likely to be named after.
  @closed_class MapSet.new(~w(
    a an the this that these those
    i me my mine myself you your yours yourself
    he him his himself she her hers herself it its itself
    we us our ours ourselves they them their theirs themselves
    who whom whose which what
    and or but nor for yet so
    if then else when while because although though unless until
    at by from in into of off on onto out over to under up with within without
    is am are was were be been being do does did done have has had having
    can could might must shall should would
    not no nor none any some each every all both few many most other another
    here there now then today tomorrow yesterday
  ))

  @doc """
  Picks the label for one card from the surface forms of its own sources.

  `forms` is every surface form the card's mentions carry, one entry per mention, so repetition
  across source statements is what gives a form its frequency.

  Selection is by frequency, then shortest, then lexical order. Shortest matters more than it
  looks: the mention spotter joins capitalised words across `\\s+`, which spans newlines and
  sentence boundaries, so the longest candidate is usually an artefact. Per-statement dedup also
  means a two- or three-source card is normally a frequency tie, which leaves the tie-break
  deciding most labels.

  Returns `nil` when every candidate is rejected. The caller renders an ordinal instead.
  """
  def label(forms) when is_list(forms) do
    forms
    |> Enum.filter(&usable?/1)
    |> Enum.frequencies()
    |> Enum.min_by(
      fn {form, count} -> {-count, String.length(form), form} end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      {form, _count} -> form
    end
  end

  @doc """
  Classifies a card from the surface forms of its own sources.

  Unlike `label/1` this considers every form, including ones too untidy to display: an email
  address is a poor label and an excellent `person` signal. Resolution follows the precedence
  `infer_kind/1` already documents, so an address that also carries a company suffix stays a
  person.

  Returns `nil` only when `forms` is empty.
  """
  def kind([]), do: nil

  def kind(forms) when is_list(forms) do
    kinds =
      forms
      |> Enum.uniq()
      |> MapSet.new(&EntityResolver.infer_kind/1)

    Enum.find(~w(person org system concept), &MapSet.member?(kinds, &1))
  end

  # Rejects forms that cannot read as a name. The period rule targets `". "` rather than any
  # period, because the spotter admits periods inside a single token: rejecting all of them would
  # discard every email address, and with it every `person` classification.
  defp usable?(form) do
    String.length(form) > 1 and
      not String.contains?(form, ". ") and
      not String.contains?(form, "  ") and
      not String.match?(form, ~r/[\r\n\t]/) and
      not MapSet.member?(@closed_class, String.downcase(form))
  end
end
