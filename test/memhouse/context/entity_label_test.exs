# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.EntityLabelTest do
  use ExUnit.Case, async: true

  alias MemHouse.Context.EntityLabel

  describe "label/1" do
    test "prefers the form carried by the most source statements" do
      # The winner is both longer and lexically larger than its rival, so only frequency can
      # explain the result. A sort key that dropped the count would return "Helix".
      forms = ["Helix Platform", "Helix Platform", "Helix"]

      assert EntityLabel.label(forms) == "Helix Platform"
    end

    test "breaks a frequency tie on the shortest form, not the lexically smallest" do
      # The spotter joins capitalised words across whitespace, so the longest candidate is
      # usually the artefact rather than the name. Per-statement dedup makes a small card a
      # frequency tie almost every time, which leaves this rule deciding most labels. "Zebra"
      # is lexically larger, so a key without the length term would return the artefact.
      forms = ["Zebra", "Aardvark Systems Group"]

      assert EntityLabel.label(forms) == "Zebra"
    end

    test "breaks a length tie lexically, so a rebuild picks the same form" do
      assert EntityLabel.label(["Zeta", "Beta"]) == "Beta"
      assert EntityLabel.label(["Beta", "Zeta"]) == "Beta"
    end

    test "weighs frequency above length" do
      # Guards the sign on the count term. Flip it and the rarer, shorter form wins.
      forms = ["Continental Reinsurance", "Continental Reinsurance", "Zed"]

      assert EntityLabel.label(forms) == "Continental Reinsurance"
    end

    test "rejects a form that spans a sentence boundary" do
      assert EntityLabel.label(["Taylor. Taylor", "Taylor"]) == "Taylor"
      assert EntityLabel.label(["Taylor. Taylor"]) == nil
    end

    test "keeps a period inside a single token" do
      # Rejecting every period would discard email addresses, and with them every person
      # classification.
      assert EntityLabel.label(["alex@corp.example"]) == "alex@corp.example"
      assert EntityLabel.label(["Node.js"]) == "Node.js"
    end

    test "rejects newlines, tabs, and doubled spaces" do
      assert EntityLabel.label(["Ada\nLovelace"]) == nil
      assert EntityLabel.label(["Ada\tLovelace"]) == nil
      assert EntityLabel.label(["Ada  Lovelace"]) == nil
    end

    test "rejects a form that is itself a closed-class word, whatever its case" do
      assert EntityLabel.label(["The"]) == nil
      assert EntityLabel.label(["the"]) == nil
      assert EntityLabel.label(["THEY"]) == nil
      assert EntityLabel.label(["It", "Ada"]) == "Ada"
    end

    test "keeps modal verbs that are also given names" do
      # Case-folded matching cannot tell "Will" the name from "will" the verb, so the list omits
      # both. Losing a person's label is the worse error.
      assert EntityLabel.label(["Will"]) == "Will"
      assert EntityLabel.label(["May"]) == "May"
    end

    test "does not claim to strip a determiner absorbed into a multiword form" do
      # The spotter emits `The Helix API` as one form. No token filter removes that leading
      # determiner, and the guarantee is only that a form which *is* a closed-class word loses.
      assert EntityLabel.label(["The Helix API"]) == "The Helix API"
    end

    test "returns nil when every candidate is rejected" do
      assert EntityLabel.label(["the", "A", "of"]) == nil
      assert EntityLabel.label([]) == nil
    end
  end

  describe "kind/1" do
    test "resolves by precedence rather than by frequency" do
      # An address outranks a company suffix even when the suffix is more common, because
      # infer_kind/1 documents that ordering and both must agree.
      forms = ["Corp Holdings", "Corp Holdings", "alex@corp.example"]

      assert EntityLabel.kind(forms) == "person"
    end

    test "classifies organisations, systems, and the catch-all" do
      assert EntityLabel.kind(["Helix LLC"]) == "org"
      assert EntityLabel.kind(["Billing API"]) == "system"
      assert EntityLabel.kind(["billing service"]) == "concept"
    end

    test "considers forms too untidy to display" do
      # An email is a poor label and an excellent person signal, so kind sees the unfiltered set.
      assert EntityLabel.label(["alex@corp.example. Ada"]) == nil
      assert EntityLabel.kind(["alex@corp.example. Ada"]) == "person"
    end

    test "returns nil only when there are no forms" do
      assert EntityLabel.kind([]) == nil
    end
  end
end
