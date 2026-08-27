# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.F11EvaluationCiReleaseReadinessTest do
  @moduledoc """
  Pins version discipline, evaluation provenance and floors, CI parity, and
  shipped-surface claims.

  Repository-file assertions protect SemVer/changelog agreement, held-out
  tuning, benchmark ablations, both database lanes, release/container builds,
  entity-cache privacy, unavailable-surface inventory, and independent recorded
  model judging. Removing a gate must fail here rather than weaken a release.

  `f11-1` versions reports; `f11-suite-1` versions the release bundle; `f7-1`
  and `f5-1` identify retrieval and extraction inside reports. These external
  identities require a changelog and refreshed evidence when changed.
  """

  use ExUnit.Case, async: false

  alias MemHouse.Eval.ModelJudge
  alias MemHouse.Eval.Report
  alias MemHouse.Model.CassetteProvider
  alias MemHouse.ReleaseReadiness

  test "documented Mix tasks use the memhouse command namespace" do
    Mix.Task.load_all()

    for task <- [
          "memhouse.eval.benchmark",
          "memhouse.eval.experiment",
          "memhouse.eval.release",
          "memhouse.eval.smoke",
          "memhouse.eval.verify",
          "memhouse.identity.bootstrap",
          "memhouse.portability.export",
          "memhouse.portability.import",
          "memhouse.reembed",
          "memhouse.release.check"
        ] do
      assert Mix.Task.get(task), "expected mix #{task} to be registered"
    end
  end

  test "semantic application version has a dated changelog entry and F11 documentation" do
    # The version the build declares. When this changes, the changelog entry, the tag, and
    # the surface inventory release field below all have to change with it.
    assert ReleaseReadiness.mix_version!(File.cwd!()) == "0.4.0"

    # Metadata-only pass: version syntax, dated changelog entry, and agreement between the
    # documents a releaser reads. Evaluation evidence is skipped here because a real report
    # requires a full benchmark run; the release command itself demands one.
    assert %{status: :ready, version: "0.4.0"} =
             ReleaseReadiness.check!(allow_missing_eval: true)
  end

  test "public eval evidence fails closed on missing reproducibility identity" do
    report = valid_report()
    assert Report.validate(report) == :ok

    # Remove one reproducibility field and the whole report becomes invalid. Retrieval
    # ranking behaviour is versioned, so a score without the profile version cannot be
    # compared against any other score — validation refuses rather than degrading silently.
    assert {:error, errors} = report |> Map.delete("profile_version") |> Report.validate()
    assert "profile_version must identify exactly one profile version" in errors

    # Thresholds are a floor, and falling below one raises rather than warns. The fixture
    # scores 0.5 accuracy against a demanded 1.0, so this must fail — a regression must stop
    # a release, not appear in a log nobody reads.
    assert_raise ArgumentError, ~r/eval regression/, fn ->
      Report.assert_thresholds!(report, %{
        "benchmarks" => %{"locomo" => %{"balanced" => %{"accuracy" => 1.0}}}
      })
    end
  end

  test "release suite separates held-out tuning and published splits and covers the matrix" do
    suite = "test/fixtures/eval/release-suite.json" |> File.read!() |> Jason.decode!()
    runs = suite["runs"]

    assert suite["suite_version"] == "f11-1"
    # The split used to tune ranking weights must never be the split whose results are
    # published. Tuning on the reported data inflates every number and cannot be detected
    # from the numbers themselves, so it is enforced structurally here.
    refute suite["tuning_policy"]["tuning_split"] == suite["tuning_policy"]["published_split"]

    assert MapSet.new(Enum.map(runs, & &1["benchmark"])) ==
             MapSet.new(~w(memhouse locomo longmemeval convomem beam))

    for benchmark <- ~w(locomo longmemeval convomem beam) do
      variants = Enum.filter(runs, &(&1["benchmark"] == benchmark))
      # Three variants per external benchmark: the named profile (no strategy override, so
      # `strategies` is null), plus two single-strategy ablations. Without the ablations a
      # headline number cannot be attributed — you cannot tell whether the full pipeline
      # actually beats plain keyword search or plain recency.
      assert Enum.any?(variants, &is_nil(&1["strategies"]))
      assert Enum.any?(variants, &(&1["strategies"] == ["lexical"]))
      assert Enum.any?(variants, &(&1["strategies"] == ["salience_recency"]))
      # Deadlines off for every published run: a timing-dependent cutoff would make results
      # depend on how loaded the machine was, and quality would stop being comparable.
      assert Enum.all?(variants, &(&1["deadline"] == "disabled"))
    end
  end

  test "CI gates both database modes, builds releases, and has no retired SQLite lane" do
    ci = File.read!(".github/workflows/ci.yml")
    nightly = File.read!(".github/workflows/eval.yml")
    release = File.read!(".github/workflows/release.yml")
    prepare_release = File.read!(".github/workflows/prepare-release.yml")
    publish_release = File.read!(".github/workflows/publish-release.yml")

    # Each of these is a gate someone could delete to make a red build go green: schema-drift
    # detection, formatting, warnings-as-errors, the test suite, linting, type checking,
    # security scanning, the evaluation run, the release metadata check, and proof that both
    # the release and the container still build. Asserting on the workflow text is crude but
    # it is the only thing that notices a removed step.
    for command <- [
          "mix ash.codegen --check",
          "mix format --check-formatted",
          "mix compile --warnings-as-errors",
          "mix test",
          "mix credo --strict",
          "mix dialyzer",
          "mix sobelow --config",
          "mix memhouse.eval.release",
          "mix memhouse.release.check",
          "mix release --overwrite",
          "./scripts/ci-campaign-build-revision"
        ] do
      assert ci =~ command
    end

    # Both database configurations run the same suite. Losing either lane means the two
    # deployment modes stop being verified as equivalent.
    assert ci =~ "external Postgres"
    assert ci =~ "packaged pg0"
    # A retired embedded engine that must not return: it cannot provide the vector and
    # full-text behaviour the product depends on, so supporting it would fork the guarantees.
    refute String.downcase(ci) =~ "sqlite"
    # The nightly evaluation workflow runs on a schedule and provisions its own database.
    assert nightly =~ "schedule:"
    assert nightly =~ "mix ecto.create"
    assert nightly =~ "mix ecto.migrate"
    # Publishing a GitHub Release selects the existing semantic tag. A tag push alone
    # cannot ship an artifact, while a maintainer can retry a repaired workflow against
    # that same tag. Both paths still validate the selected commit.
    assert release =~ "types: [published]"
    assert release =~ "workflow_dispatch:"
    assert release =~ "Existing semantic release tag to rebuild and publish"
    refute release =~ "tags: [\"v*.*.*\"]"
    assert release =~ "./scripts/ci-pg0-lane"

    # Successful GitHub Release runs retain both distribution paths in GitHub. Release assets
    # are durable and version-scoped; the container uses the repository package instead of a
    # long-lived registry credential.
    assert release =~ "contents: write"
    assert release =~ "packages: write"
    assert release =~ "gh release upload"
    assert release =~ "docker push"
    assert release =~ "ghcr.io/${GITHUB_REPOSITORY,,}"
    assert release =~ "if [[ \"$version\" != *-* ]]"
    assert release =~ "github.event.release.tag_name || inputs.tag"
    # Every supported package needs matching ERTS, NIFs, pg0, and pgvectorscale binaries.
    assert release =~ "runner: macos-26"
    assert release =~ "runs-on: ubuntu-24.04-arm"
    assert release =~ "memhouse-linux-arm64.tar.gz"
    assert release =~ "memhouse-macos-arm64.tar.gz"
    refute release =~ "memhouse-macos-x86_64.tar.gz"
    refute release =~ "memhouse-windows-x86_64.zip"
    assert release =~ "actions/download-artifact@v8"
    assert release =~ "needs: [linux, linux-arm64, macos]"

    # The manually-dispatched release preparer changes the metadata before it
    # tags, then publishes the GitHub Release that invokes the artifact lane.
    assert prepare_release =~ "workflow_dispatch:"
    assert prepare_release =~ "replace_existing_release"
    assert prepare_release =~ "actions/cache@v6"
    assert prepare_release =~ "hashFiles('mix.lock')"
    assert prepare_release =~ "mix compile --warnings-as-errors"
    assert prepare_release =~ "mix memhouse.release.check"
    assert prepare_release =~ "branch=\"\${branch}-repair\""
    assert prepare_release =~ "gh pr create"
    assert prepare_release =~ "timescale/timescaledb-ha:pg18-all-oss"
    assert prepare_release =~ "MEMHOUSE_TEST_DATABASE_URL"
    assert publish_release =~ "pull_request:"
    assert publish_release =~ "types: [closed]"
    assert publish_release =~ "git config user.name \"github-actions[bot]\""
    assert publish_release =~ "tag=\"\${tag%-repair}\""
    assert publish_release =~ "github.event.pull_request.merged == true"
    assert publish_release =~ "gh release create"
    assert publish_release =~ "gh workflow run release.yml"
  end

  test "entity and mention caches remain absent from every current public surface" do
    public_routes =
      MemHouseWeb.Router.__routes__()
      |> Enum.map_join("\n", fn route -> "#{route.verb} #{route.path}" end)
      |> String.downcase()

    router = File.read!("lib/memhouse_web/router.ex") |> String.downcase()
    sdk = Path.wildcard("sdk/**/*.*") |> Enum.map_join("\n", &File.read!/1) |> String.downcase()

    # Entities and their mentions are a private recall cache built from governed statements.
    # Exposing them would create a second, ungoverned view of who an account knows about,
    # bypassing the approval and consent rules that apply to knowledge itself.
    #
    # Checked three ways because each catches a different mistake: compiled routes catch a
    # route added anywhere, the router source catches a resource wired in by an atom, and the
    # client helper sources catch a field name that leaked into a published type definition.
    refute public_routes =~ "entity"
    refute public_routes =~ "mention"
    refute router =~ ":entity"
    refute router =~ ":mention"
    refute sdk =~ "entity_id"
    refute sdk =~ "entitymention"
  end

  test "release installation docs select and verify every published platform archive" do
    install = File.read!("docs/getting-started/install-release.md")

    for archive <- [
          "memhouse-linux-x86_64.tar.gz",
          "memhouse-linux-arm64.tar.gz",
          "memhouse-macos-arm64.tar.gz"
        ] do
      assert install =~ archive
    end

    assert install =~ "shasum -a 256 -c"
    assert install =~ "sha256sum -c"
    assert install =~ "bin/server"
    assert install =~ "external PostgreSQL"
    assert install =~ "Open Anyway"
  end

  test "surface inventory gates shipped contracts and fails closed around the integration-surfaces boundary" do
    inventory =
      "test/fixtures/eval/surface-contract-inventory.json"
      |> File.read!()
      |> Jason.decode!()

    # The inventory is the machine-readable answer to "what does this release actually
    # offer?". It is versioned with the application so a consumer can trust it.
    assert inventory["release"] == "0.4.0"

    # "gated" means the surface ships and has a test lane holding its contract in place.
    assert inventory["surfaces"]["phoenix_http"]["status"] == "gated"
    assert inventory["surfaces"]["mcp"]["status"] == "gated"
    assert inventory["surfaces"]["skill_readiness_helpers"]["status"] == "gated"
    assert inventory["surfaces"]["browser_console"]["status"] == "gated"

    # Every gated surface names the test lanes that hold its contract. A surface listed as
    # shipped with no evidence is the failure this assertion exists to catch: it would let a
    # release advertise something no test protects.
    for surface <- ~w(phoenix_http mcp skill_readiness_helpers browser_console) do
      assert inventory["surfaces"][surface]["evidence"] != []

      for path <- inventory["surfaces"][surface]["evidence"] do
        assert File.exists?(path), "#{surface} names missing evidence #{path}"
      end
    end

    # "unavailable" means not built yet, and it must stay that way until it is. Generated API
    # schemas and generated clients do not exist at this version; the hand-written readiness
    # helper modules are not substitutes for them. Marking one of these shipped — or dropping
    # it from the inventory so no lane is missing — would make the release overstate itself.
    for surface <- ~w(ash_json_api_openapi generated_typescript_sdk generated_python_sdk) do
      assert inventory["surfaces"][surface]["status"] == "unavailable"
      assert inventory["surfaces"][surface]["prerequisite"] == "integration-surfaces"
    end
  end

  test "provider cassette replays an independent-family model judge deterministically" do
    original_roles = Application.fetch_env!(:memhouse, :model_roles)
    original_provider = Application.get_env(:memhouse, :model_provider)

    # The judge runs on the reasoning role, which must resolve to a different provider or
    # model family than the role that produced the answers. A model grading its own family's
    # output is not an independent measurement.
    roles =
      Keyword.update!(original_roles, :dream_reasoner, fn config ->
        config
        |> Map.put(:provider, "cassette")
        |> Map.put(:model, "independent-rag-judge")
        |> Map.put(:model_version, "judge-1")
      end)

    Application.put_env(:memhouse, :model_roles, roles)
    Application.put_env(:memhouse, :model_provider, CassetteProvider)
    # Replaying a recorded verdict makes the judged score deterministic. A live judge would
    # make this test flaky and would make published scores unreproducible.
    CassetteProvider.start!("test/fixtures/model/f11-judge-cassette.json", "rag_triad")

    on_exit(fn ->
      CassetteProvider.stop()
      Application.put_env(:memhouse, :model_roles, original_roles)

      if original_provider,
        do: Application.put_env(:memhouse, :model_provider, original_provider),
        else: Application.delete_env(:memhouse, :model_provider)
    end)

    score =
      ModelJudge.score(
        "What format is preferred?",
        "Concise bullet points.",
        [%{"statement" => "Concise bullet points are preferred."}]
      )

    # Three separate axes, not one blended score: whether the answer is supported by the
    # retrieved material, whether that material was relevant to the question, and whether the
    # answer addresses the question. They fail independently and must stay distinguishable.
    # The values come from the recorded verdict, normalised from its 1-5 integer scale.
    assert score["model_groundedness"] == 1.0
    assert score["model_context_relevance"] == 0.75
    assert score["model_answer_relevance"] == 0.5
    # The judge's identity travels with the score, because a score is only interpretable
    # alongside who produced it.
    assert score["model_judge"]["model"] == "independent-rag-judge"
    # Exactly one provider call, on the reasoning role, for the judging task. More calls
    # would mean retries or leakage of the answer into another request.
    assert CassetteProvider.calls() == [{"structured", "dream_reasoner", "eval_judge"}]
  end

  # A minimal report that passes validation, used as the baseline the negative cases mutate.
  #
  # Every field here is load-bearing for reproducibility, which is why validation rejects a
  # report missing any of them: the application version, the exact retrieval profile version,
  # any strategy override, the deadline setting, the run limits, the dataset identity with
  # its digest and split, all five model-role identities, and how the answers were graded.
  # Together they are the complete recipe for re-running the measurement.
  defp valid_report do
    %{
      "report_schema" => "f11-1",
      "cartulary_version" => "0.2.0",
      "generated_at" => "2026-07-28T12:00:00Z",
      "benchmark" => "locomo",
      "profile" => "balanced",
      "profile_version" => "f7-1",
      "strategies" => nil,
      "deadline" => "disabled",
      "limits" => %{
        "cases" => nil,
        "messages_per_case" => nil,
        "questions_per_case" => nil
      },
      "dataset" => %{
        "id" => "locomo.json",
        "sha256" => String.duplicate("a", 64),
        "split" => "release-evaluation"
      },
      "model_roles" =>
        Map.new(~w(embedder reranker ingest_extractor dream_reasoner dialectic_agent), fn role ->
          {role,
           %{
             "provider" => "deterministic",
             "model" => "fixture",
             "version" => "1",
             "prompt_version" => "1",
             "pipeline_version" => "f5-1"
           }}
        end),
      "judge" => %{"kind" => "deterministic", "method" => "deterministic-lexical-f11-1"},
      "metrics" => %{
        "overall" => %{
          "accuracy" => 0.5,
          "abstention_accuracy" => nil,
          "citation_hit_rate" => 0.5,
          "mean_citation_recall" => 0.5,
          "mean_groundedness" => 0.5,
          "mean_context_relevance" => 0.5,
          "mean_answer_relevance" => 0.5,
          "mean_end_to_end_tokens" => 10.0,
          "mean_full_context_tokens" => 20.0,
          "mean_token_efficiency_ratio" => 0.5
        }
      }
    }
  end

  defp empty_lifecycle_evidence do
    %{
      "visibility" => "internal_account_scope_all_states",
      "final_states" => Map.new(MemHouse.Knowledge.Lifecycle.states(), &{&1, 0}),
      "absent_final_states" => MemHouse.Knowledge.Lifecycle.states(),
      "exercised_states" => [],
      "unexercised_states" => MemHouse.Knowledge.Lifecycle.states(),
      "unexercised_reasons" =>
        Map.new(
          MemHouse.Knowledge.Lifecycle.states(),
          &{&1, MemHouse.Knowledge.Lifecycle.absence_reason(&1)}
        ),
      "transitions" => [],
      "audit_transitions" => [],
      "lifecycle_events" => 0,
      "lifecycle_audit_events" => 0
    }
  end

  test "f11-2 requires balanced one-time accounting while reading f11-1 remains compatible" do
    legacy = valid_report()
    assert MemHouse.Eval.Report.validate(legacy) == :ok

    current =
      legacy
      |> Map.put("report_schema", "f11-2")
      |> Map.put("memhouse_version", Map.fetch!(legacy, "cartulary_version"))
      |> Map.delete("cartulary_version")
      |> Map.merge(%{
        "available" => 5,
        "sampled" => 5,
        "attempted" => 4,
        "evaluated" => 2,
        "skipped" => 1,
        "failed" => 1,
        "cancelled" => 1
      })
      |> Map.put("accounting", %{
        "available" => 5,
        "sampled" => 5,
        "attempted" => 4,
        "evaluated" => 2,
        "skipped" => 1,
        "failed" => 1,
        "cancelled" => 1,
        "items" => [
          %{"id" => "a", "status" => "evaluated"},
          %{"id" => "b", "status" => "evaluated"},
          %{"id" => "c", "status" => "skipped", "reason" => "filtered"},
          %{"id" => "d", "status" => "failed", "reason" => "adapter_error"},
          %{"id" => "e", "status" => "cancelled", "reason" => "cancelled"}
        ]
      })
      |> Map.put("lifecycle", empty_lifecycle_evidence())

    assert MemHouse.Eval.Report.validate(current) == :ok

    all_evaluated =
      current
      |> Map.merge(%{
        "attempted" => 5,
        "evaluated" => 5,
        "skipped" => 0,
        "failed" => 0,
        "cancelled" => 0
      })
      |> put_in(["accounting", "attempted"], 5)
      |> put_in(["accounting", "evaluated"], 5)
      |> put_in(["accounting", "skipped"], 0)
      |> put_in(["accounting", "failed"], 0)
      |> put_in(["accounting", "cancelled"], 0)
      |> update_in(["accounting", "items"], fn items ->
        Enum.map(items, fn item ->
          item
          |> Map.put("status", "evaluated")
          |> Map.drop(["reason"])
        end)
      end)

    assert MemHouse.Eval.Report.validate(all_evaluated) == :ok

    invalid = put_in(current, ["accounting", "items", Access.at(4), "id"], "d")
    assert {:error, errors} = MemHouse.Eval.Report.validate(invalid)
    assert Enum.any?(errors, &String.contains?(&1, "accounting"))
  end

  test "f11-3 lifecycle evidence includes every state and balances transition audits" do
    lifecycle =
      empty_lifecycle_evidence()
      |> put_in(["final_states", "proposed"], 2)
      |> Map.put("absent_final_states", MemHouse.Knowledge.Lifecycle.states() -- ["proposed"])
      |> Map.put("exercised_states", ["proposed"])
      |> Map.put("unexercised_states", MemHouse.Knowledge.Lifecycle.states() -- ["proposed"])
      |> Map.put(
        "unexercised_reasons",
        Map.new(
          MemHouse.Knowledge.Lifecycle.states() -- ["proposed"],
          &{&1, MemHouse.Knowledge.Lifecycle.absence_reason(&1)}
        )
      )
      |> Map.put("transitions", [
        %{
          "from_state" => nil,
          "to_state" => "proposed",
          "reason" => "f4_pipeline_proposed",
          "count" => 2
        }
      ])
      |> Map.put("audit_transitions", [
        %{
          "from_state" => nil,
          "to_state" => "proposed",
          "reason" => "f4_pipeline_proposed",
          "count" => 2
        }
      ])
      |> Map.put("lifecycle_events", 2)
      |> Map.put("lifecycle_audit_events", 2)

    report =
      valid_report()
      |> Map.put("report_schema", "f11-3")
      |> Map.put("memhouse_version", "0.4.0")
      |> Map.delete("cartulary_version")
      |> Map.merge(%{
        "available" => 0,
        "sampled" => 0,
        "attempted" => 0,
        "evaluated" => 0,
        "skipped" => 0,
        "failed" => 0,
        "cancelled" => 0,
        "accounting" => %{
          "available" => 0,
          "sampled" => 0,
          "attempted" => 0,
          "evaluated" => 0,
          "skipped" => 0,
          "failed" => 0,
          "cancelled" => 0,
          "items" => []
        },
        "lifecycle" => lifecycle
      })

    assert Report.validate(report) == :ok

    assert {:error, errors} =
             report
             |> put_in(["lifecycle", "lifecycle_audit_events"], 1)
             |> Report.validate()

    assert Enum.any?(errors, &String.contains?(&1, "lifecycle"))

    assert {:error, errors} =
             report
             |> put_in(["lifecycle", "transitions", Access.at(0), "to_state"], "active")
             |> Report.validate()

    assert Enum.any?(errors, &String.contains?(&1, "lifecycle"))
  end

  test "durability audit evidence is content-safe and count-balanced" do
    report =
      valid_report()
      |> Map.put("durability", %{
        "method" => "deterministic-durability-f11-1",
        "judge" => %{
          "kind" => "deterministic",
          "method" => "deterministic-durability-f11-1"
        },
        "available" => 4,
        "sampled" => 4,
        "sample_seed" => "issue-160",
        "categories" => %{
          "durable" => 2,
          "greeting_or_small_talk" => 1,
          "question" => 1,
          "speech_act_transcription" => 0,
          "subjectless_generic" => 0,
          "other_non_durable" => 0
        },
        "durable" => 2,
        "noise" => 2,
        "messages" => %{"zero" => 1, "one" => 2, "multiple" => 1}
      })

    assert Report.validate(report) == :ok

    invalid = put_in(report, ["durability", "noise"], 1)
    assert {:error, errors} = Report.validate(invalid)
    assert "durability must contain balanced, content-safe audit counts" in errors
  end

  test "dream-time evidence balances terminal passes and requires a clean replay" do
    report =
      valid_report()
      |> Map.put("reasoning", %{
        "enabled" => true,
        "attempted" => 2,
        "completed" => 1,
        "throttled" => 0,
        "failed" => 1,
        "replayed" => 1,
        "replay_durable_effects" => 0,
        "knowledge_before" => 2,
        "knowledge_after" => 3,
        "superseded" => 0,
        "relations" => %{"supports" => 1},
        "deductions" => %{"active" => 1},
        "conflict_validation_items" => 0,
        "corroboration" => %{"1" => 3},
        "reasoner" => %{
          "calls" => 2,
          "input_tokens" => 10,
          "output_tokens" => 5,
          "latency_ms" => 20,
          "error_classes" => %{"timeout" => 1}
        }
      })

    assert Report.validate(report) == :ok

    assert {:error, errors} =
             report |> put_in(["reasoning", "replay_durable_effects"], 1) |> Report.validate()

    assert "reasoning must balance terminal passes and show a zero-effect replay" in errors
  end

  test "dream-time evidence is optional for historical and ordinary reports" do
    assert Report.validate(valid_report()) == :ok
    assert Report.validate(Map.put(valid_report(), "reasoning", nil)) == :ok
  end
end
