%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "examples/"]},
      plugins: [{AshCredo, []}],
      strict: true,
      checks: %{
        extra: [
          # Shared Leaf checks on top of Credo defaults, without app-specific relaxations.
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Credo.Check.Design.AliasUsage,
           [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 0]},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Readability.WithSingleClause, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.IoPuts, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.WrongTestFileExtension, []},
          # The remaining opinionated Ash checks retain the plugin's disabled defaults.
          {AshCredo.Check.Warning.CompileTimeDefault, []},
          {AshCredo.Check.Warning.MissingBuiltinWrapper, []},
          {AshCredo.Check.Warning.MissingMacroDirective, []},
          {AshCredo.Check.Warning.PinnedTimeInExpression, []},
          {AshCredo.Check.Warning.AuthorizerWithoutPolicies, []},
          {AshCredo.Check.Warning.MissingDomain, []},
          {AshCredo.Check.Warning.RedundantValidation, []},
          {AshCredo.Check.Warning.SensitiveAttributeExposed, []},
          {AshCredo.Check.Warning.UnknownAction, []},
          {AshCredo.Check.Refactor.DirectiveInFunctionBody, []}
        ]
      }
    }
  ]
}
