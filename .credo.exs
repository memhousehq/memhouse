# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0
#
# Credo configuration, run as `mix credo --strict` for changes that touch non-trivial logic.
#
# Two entries are load-bearing for readability and worth knowing about: -
# Readability.ModuleDoc is ON: every module needs a moduledoc. Credo is satisfied by
# `@moduledoc false`; this repository is not — a first-party module must carry a real one. -
# Design.AliasUsage is OFF. Fully-qualified calls are allowed where they make the origin of a
# function obvious at the call site.

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "config/",
          "lib/",
          "test/"
        ],
        excluded: [
          "_build/",
          "deps/"
        ]
      },
      checks: [
        {Credo.Check.Consistency.ExceptionNames, []},
        {Credo.Check.Consistency.LineEndings, []},
        {Credo.Check.Consistency.ParameterPatternMatching, []},
        {Credo.Check.Consistency.SpaceAroundOperators, []},
        {Credo.Check.Consistency.SpaceInParentheses, []},
        {Credo.Check.Consistency.TabsOrSpaces, []},
        # Fully-qualified calls are allowed; see the note at the top of the file.
        {Credo.Check.Design.AliasUsage, false},
        # TODO and FIXME markers are reported. Unfinished work belongs in an
        # issue with acceptance criteria, not in a comment nobody sees again.
        {Credo.Check.Design.TagFIXME, []},
        {Credo.Check.Design.TagTODO, []},
        {Credo.Check.Readability.AliasOrder, []},
        {Credo.Check.Readability.FunctionNames, []},
        {Credo.Check.Readability.LargeNumbers, []},
        # 100 columns. The low priority only hides violations from a bare
        # `mix credo`; `--strict`, which is how this repository runs it, reports
        # them and fails on them like any other check.
        {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 100]},
        {Credo.Check.Readability.ModuleAttributeNames, []},
        # Enforces that a moduledoc exists. `@moduledoc false` satisfies this
        # check but is not accepted in first-party code here.
        {Credo.Check.Readability.ModuleDoc, []},
        {Credo.Check.Readability.ModuleNames, []},
        {Credo.Check.Readability.ParenthesesInCondition, []},
        {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
        {Credo.Check.Readability.PredicateFunctionNames, []},
        {Credo.Check.Readability.PreferImplicitTry, []},
        {Credo.Check.Readability.RedundantBlankLines, []},
        {Credo.Check.Readability.Semicolons, []},
        {Credo.Check.Readability.SpaceAfterCommas, []},
        {Credo.Check.Readability.StringSigils, []},
        {Credo.Check.Readability.TrailingBlankLine, []},
        {Credo.Check.Readability.TrailingWhiteSpace, []},
        {Credo.Check.Refactor.Apply, []},
        {Credo.Check.Refactor.CondStatements, []},
        # Raised from Credo's default of 9. The governance gate matrix and the
        # retrieval fusion path branch widely by nature; 12 keeps genuinely
        # tangled functions flagged without forcing artificial extraction.
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
        {Credo.Check.Refactor.FunctionArity, []},
        {Credo.Check.Refactor.LongQuoteBlocks, []},
        {Credo.Check.Refactor.MatchInCondition, []},
        {Credo.Check.Refactor.NegatedConditionsInUnless, []},
        {Credo.Check.Refactor.NegatedConditionsWithElse, []},
        # Raised from Credo's default of 2 to accommodate `with` chains inside
        # Ash transaction callbacks, which are one level deeper by construction.
        {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
        {Credo.Check.Refactor.UnlessWithElse, []},
        {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
        {Credo.Check.Warning.BoolOperationOnSameValues, []},
        {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
        {Credo.Check.Warning.IExPry, []},
        {Credo.Check.Warning.IoInspect, []},
        {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
        {Credo.Check.Warning.OperationOnSameValues, []},
        {Credo.Check.Warning.OperationWithConstantResult, []},
        {Credo.Check.Warning.RaiseInsideRescue, []},
        {Credo.Check.Warning.SpecWithStruct, []},
        {Credo.Check.Warning.UnsafeExec, []},
        {Credo.Check.Warning.UnusedEnumOperation, []},
        {Credo.Check.Warning.UnusedFileOperation, []},
        {Credo.Check.Warning.UnusedKeywordOperation, []},
        {Credo.Check.Warning.UnusedListOperation, []},
        {Credo.Check.Warning.UnusedPathOperation, []},
        {Credo.Check.Warning.UnusedRegexOperation, []},
        {Credo.Check.Warning.UnusedStringOperation, []},
        {Credo.Check.Warning.UnusedTupleOperation, []}
      ]
    }
  ]
}
