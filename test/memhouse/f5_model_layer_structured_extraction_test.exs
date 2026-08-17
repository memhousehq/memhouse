# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.F5ModelLayerStructuredExtractionTest do
  @moduledoc """
  Pins the provider-neutral gateway and structured-extraction contract.

  The suite fixes five model roles and provider callbacks; offline embedder
  behavior; secret-reference storage; bounded schema repair; independent
  subject resolution; complete model provenance; exact usage emission;
  explicit vector re-embedding; and retryable provider failure.

  `f5-1` identifies extraction and pipeline behavior in health, provenance,
  usage, and re-embed plans. Changing it requires a changelog and new evidence.
  Provider call-sequence changes must update the recorded cassette, not loosen
  matching.

  Runs synchronously because it changes node-global model configuration.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Memory
  alias MemHouse.Model
  alias MemHouse.Model.CassetteProvider
  alias MemHouse.Model.Embedding
  alias MemHouse.Model.Embedding.Ortex
  alias MemHouse.Model.ModelRoleConfig
  alias MemHouse.Model.Providers.Ortex, as: OrtexProvider
  alias MemHouse.Model.Reasoner
  alias MemHouse.Model.Schema.DialecticAnswer
  alias MemHouse.Operations.Metering

  # Recorded provider script replayed instead of any network call. Each scenario inside it
  # is an ordered list of expected calls; see the individual tests for which one they arm.
  @cassette "test/fixtures/model/f5-provider-cassette.json"

  setup do
    original_provider = Application.get_env(:memhouse, :model_provider)
    original_roles = Application.fetch_env!(:memhouse, :model_roles)

    # Application environment is node-global. Restoring it (and stopping the cassette agent,
    # which is started unlinked so a failing test cannot take it down) is mandatory: a leaked
    # half-consumed cassette makes the *next* test fail in a way that looks unrelated.
    on_exit(fn ->
      CassetteProvider.stop()

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end

      Application.put_env(:memhouse, :model_roles, original_roles)
    end)

    :ok
  end

  test "five pinned roles and one provider behaviour form the injection seam" do
    # The role set is closed and ordered. Adding or renaming a role changes what
    # every account must configure and what the readiness endpoint reports.
    assert Model.Config.roles() ==
             [:embedder, :reranker, :ingest_extractor, :dream_reasoner, :dialectic_agent]

    callbacks = MemHouse.Model.Provider.behaviour_info(:callbacks)

    # Exactly four capabilities, at these arities, are what a third-party or self-hosted
    # adapter has to implement. Changing an arity silently breaks every out-of-tree adapter.
    assert {:structured, 4} in callbacks
    assert {:chat, 3} in callbacks
    assert {:embed, 3} in callbacks
    assert {:rerank, 4} in callbacks

    assert function_exported?(MemHouse.Model.Embedding.Ortex, :dimensions, 1)
    assert function_exported?(MemHouse.Model.Embedding.Ortex, :generate, 2)

    # The local embedder must fail loudly when its ONNX/tokenizer artifacts are absent. It
    # must never download a model or fall back to a network endpoint: offline installations
    # rely on the default embedding path never leaving the machine.
    assert {:error, {:model_artifact_missing, :model_path}} =
             MemHouse.Model.Embedding.Ortex.generate(["offline"], dimensions: 384)

    assert {:error, {:model_artifact_missing, :model_path}} =
             MemHouse.Model.Reranking.Ortex.score([{"query", "document"}], [])

    # Role options hold secret *references* only. A literal credential in the options map is
    # rejected at the changeset, before it can reach the database, an export, or a log line.
    refute ModelRoleConfig
           |> Ash.Changeset.for_create(:create, %{
             role: "ingest_extractor",
             provider: "openrouter",
             model: "test",
             options: %{"api_key" => "must-not-be-persisted"}
           })
           |> Map.fetch!(:valid?)
  end

  test "an Account with a stale extractor role cannot stamp a new prompt with an old identity" do
    message = seed_raw!("f5-stale-prompt", "avery", "Avery prefers weekly summaries.")
    account_id = account_id!("f5-stale-prompt")

    put_role!(account_id, :ingest_extractor,
      provider: "openrouter",
      model: "openai/gpt-oss-120b",
      model_version: "2026-07",
      prompt_version: "extract-9",
      pipeline_version: "f5-1"
    )

    assert {:error,
            {:prompt_version_mismatch, %{expected: "extract-13", configured: "extract-9"}}} =
             Memory.extract_message_for_account(message["id"], account_id)

    assert %{rows: [[nil]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT extraction_completed_at FROM messages WHERE id = $1",
               [Ecto.UUID.dump!(message["id"])]
             )
  end

  test "structured extraction repairs once, resolves subject, and persists full provenance and usage" do
    message = seed_raw!("f5-repair", "avery", "Avery prefers weekly release summaries.")
    account_id = account_id!("f5-repair")

    put_role!(account_id, :ingest_extractor,
      provider: "openrouter",
      model: "openai/gpt-oss-120b",
      model_version: "2026-07",
      prompt_version: "extract-13",
      pipeline_version: "f5-1"
    )

    # This scenario records two structured calls: the first returns output that fails schema
    # validation, the second is the repair attempt that succeeds. Replaying it proves the
    # repair loop exists and is bounded, and that only validated output becomes knowledge.
    CassetteProvider.start!(@cassette, "repair_extraction")
    Application.put_env(:memhouse, :model_provider, CassetteProvider)

    assert {:ok, [knowledge]} = Memory.extract_message_for_account(message["id"], account_id)
    assert knowledge["statement"] == "Avery prefers weekly release summaries."
    # Subject and source are independent dimensions. Here they coincide because the peer
    # spoke about themselves, but the extractor must resolve the subject explicitly rather
    # than defaulting it to whoever sent the message.
    assert knowledge["subject_peer_id"] == message["peer_id"]
    assert knowledge["confidence"] == 1.0
    assert is_nil(knowledge["revalidate_after"])
    assert knowledge["extracting_provider"] == "openrouter"
    assert knowledge["extracting_model"] == "openai/gpt-oss-120b"
    assert knowledge["extracting_model_version"] == "2026-07"
    assert knowledge["prompt_version"] == "extract-13"
    assert knowledge["pipeline_version"] == "f5-1"

    # Two usage events, not one: the failed first attempt is metered too. Repairs cost real
    # tokens, so hiding them would understate spend. 115 input / 44 output is the sum of the
    # two recorded calls (50 + 65 and 20 + 24) and changes only if the cassette is re-recorded.
    assert %{
             rows: [
               [
                 2,
                 %Decimal{coef: 115},
                 %Decimal{coef: 44},
                 "openrouter",
                 "2026-07",
                 "extract-13",
                 "f5-1"
               ]
             ]
           } =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(*),
                      sum(input_tokens),
                      sum(output_tokens),
                      min(provider),
                      min(model_version),
                      min(prompt_version),
                      min(pipeline_version)
               FROM usage_events
               WHERE account_id = $1 AND model_role = 'ingest_extractor'
               """,
               [Ecto.UUID.dump!(account_id)]
             )

    # Provenance is what lets an operator answer "which model asserted this, under which
    # prompt and pipeline revision?" years later. All five identity columns must be present;
    # a knowledge row whose origin cannot be reconstructed is not auditable.
    assert %{rows: [["openrouter", "openai/gpt-oss-120b", "2026-07", "extract-13", "f5-1"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT extracting_provider,
                      extracting_model,
                      extracting_model_version,
                      prompt_version,
                      pipeline_version
               FROM provenances
               WHERE knowledge_item_id = $1
               """,
               [Ecto.UUID.dump!(knowledge["id"])]
             )
  end

  test "first-person extraction grounds an unknown subject in the speaker peer key" do
    message =
      seed_raw!(
        "f5-first-person-subject",
        "avery",
        "I increased quarterly revenue by closing three enterprise contracts."
      )

    account_id = account_id!("f5-first-person-subject")

    put_role!(account_id, :ingest_extractor,
      provider: "openrouter",
      model: "openai/gpt-oss-120b",
      model_version: "2026-08",
      prompt_version: "extract-13",
      pipeline_version: "f5-1"
    )

    CassetteProvider.start!(@cassette, "first_person_subject_repair")
    Application.put_env(:memhouse, :model_provider, CassetteProvider)

    assert {:ok, [knowledge]} = Memory.extract_message_for_account(message["id"], account_id)
    assert knowledge["subject_peer_id"] == message["peer_id"]

    assert knowledge["statement"] ==
             "Avery increased quarterly revenue by closing three enterprise contracts."

    assert CassetteProvider.calls() ==
             [
               {"structured", "ingest_extractor", "extraction"},
               {"structured", "ingest_extractor", "extraction"}
             ]
  end

  test "a missing structured object retries the original request within the repair budget" do
    message = seed_raw!("f5-missing-object", "avery", "Avery prefers weekly summaries.")
    account_id = account_id!("f5-missing-object")

    put_role!(account_id, :ingest_extractor,
      provider: "openrouter",
      model: "openai/gpt-oss-120b",
      model_version: "2026-08",
      prompt_version: "extract-13",
      pipeline_version: "f5-1"
    )

    CassetteProvider.start!(@cassette, "missing_then_valid")
    Application.put_env(:memhouse, :model_provider, CassetteProvider)

    assert {:ok, [knowledge]} = Memory.extract_message_for_account(message["id"], account_id)
    assert knowledge["statement"] == "Avery prefers weekly summaries."

    actor =
      DataLayer.with_account_id(
        account_id,
        [role: :account_admin, pipeline?: true],
        fn _account, actor -> actor end
      )

    assert %{attempts: 2, errors: 1} = Metering.summary(actor).model_calls
  end

  test "missing structured objects stop at the repair budget" do
    message = seed_raw!("f5-missing-exhausted", "avery", "Avery prefers weekly summaries.")
    account_id = account_id!("f5-missing-exhausted")

    put_role!(account_id, :ingest_extractor,
      provider: "openrouter",
      model: "openai/gpt-oss-120b",
      model_version: "2026-08",
      prompt_version: "extract-13",
      pipeline_version: "f5-1"
    )

    CassetteProvider.start!(@cassette, "missing_until_exhausted")
    Application.put_env(:memhouse, :model_provider, CassetteProvider)

    assert {:error, :missing_structured_object} =
             Memory.extract_message_for_account(message["id"], account_id)

    actor =
      DataLayer.with_account_id(
        account_id,
        [role: :account_admin, pipeline?: true],
        fn _account, actor -> actor end
      )

    assert %{attempts: 3, errors: 3} = Metering.summary(actor).model_calls
  end

  test "one cassette provider injects reasoner, dialectic, embedding, and rerank capabilities" do
    _message = seed_raw!("f5-capabilities", "avery", "Avery prefers weekly summaries.")
    account_id = account_id!("f5-capabilities")

    put_role!(account_id, :embedder,
      provider: "ortex",
      model: "test-embedder",
      model_version: "vector-space-3",
      prompt_version: "none",
      pipeline_version: "f5-1",
      # Three dimensions instead of the production 384 keeps the recorded vectors readable.
      embedding_dimensions: 3
    )

    # One scenario drives all four capabilities in the recorded order: reasoning, dialectic
    # answering, embedding, reranking. Consuming them in order proves the gateway routes each
    # role to the right capability and does not make extra or reordered provider calls.
    CassetteProvider.start!(@cassette, "capabilities")
    Application.put_env(:memhouse, :model_provider, CassetteProvider)

    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn account, actor ->
        context = %{account_id: account.id, actor: actor}

        assert {:ok, %{items: [], relations: []}, reason_provenance} =
                 Reasoner.reason(%{delta: [], working_set: []}, context)

        assert reason_provenance.pipeline_version == "f5-1"

        assert {:ok, answer, _answer_provenance} =
                 Model.generate_structured(
                   :dialectic_agent,
                   [%{role: "user", content: "What does Avery prefer?"}],
                   DialecticAnswer,
                   context,
                   task: :dialectic
                 )

        assert answer.answer == "Avery prefers weekly summaries."

        # Dimensions and version travel with the vectors, not just with the configuration, so
        # a later consumer can detect that it is holding vectors from another vector space.
        assert {:ok, embedding} = Model.embed(["first", "second"], context)
        assert embedding.dimensions == 3
        assert embedding.version == "vector-space-3"
        assert embedding.vectors == [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]

        assert {:ok, ranked, _rerank_provenance} =
                 Model.rerank("query", ["first", "second"], context)

        assert [%{"index" => 1}, %{"index" => 0}] = ranked
      end
    )

    # Four provider calls, four usage events: metering is per call, with no batching or
    # deduplication that would make the ledger disagree with what the vendor bills.
    assert scalar!(
             "SELECT count(*) FROM usage_events WHERE account_id = $1",
             [Ecto.UUID.dump!(account_id)]
           ) == 4
  end

  test "embedder identity mismatch returns a versioned re-embed plan before vector reuse" do
    current = %{
      provider: "ortex",
      model: "BAAI/bge-small-en-v1.5",
      version: "onnx-2",
      dimensions: 384
    }

    # Same provider, model, and dimension count — only the artifact version differs. That is
    # still a different vector space (the version covers the ONNX artifact, tokenizer, and
    # pooling strategy), so cosine distances between old and new vectors are meaningless.
    stored = %{current | version: "onnx-1"}

    assert {:error, {:reembed_required, plan}} =
             Embedding.ensure_compatible(stored, current)

    assert plan.pipeline_version == "f5-1"
    assert plan.from.version == "onnx-1"
    assert plan.to.version == "onnx-2"
    # The plan must never authorise partial reuse. Mixing vector spaces degrades retrieval
    # invisibly: nothing errors, results just quietly get worse.
    refute plan.reuse_existing_vectors
  end

  test "last-token pooling ignores padded positions" do
    hidden = [
      [[1.0, 0.0], [2.0, 0.0], [99.0, 0.0]],
      [[3.0, 0.0], [4.0, 0.0], [5.0, 0.0]]
    ]

    assert Ortex.last_token_pool(hidden, [[1, 1, 0], [1, 1, 1]]) ==
             [[2.0, 0.0], [5.0, 0.0]]
  end

  test "configured query prefix is applied only to query embeddings" do
    options = %{
      "query_instruction" => "Represent this sentence for searching relevant passages: "
    }

    assert OrtexProvider.apply_query_instruction(["where is the runbook?"], options,
             input_type: :query
           ) == [
             "Represent this sentence for searching relevant passages: where is the runbook?"
           ]

    assert OrtexProvider.apply_query_instruction(["The runbook is in docs."], options,
             input_type: :passage
           ) == [
             "The runbook is in docs."
           ]
  end

  test "provider outage leaves raw ingest durable and the extraction job retryable" do
    batching = Application.fetch_env!(:memhouse, :extraction_batching)
    Application.put_env(:memhouse, :extraction_batching, Keyword.put(batching, :enabled, true))
    on_exit(fn -> Application.put_env(:memhouse, :extraction_batching, batching) end)

    message = seed_raw!("f5-outage", "avery", "Avery prefers weekly summaries.")
    account_id = account_id!("f5-outage")

    put_role!(account_id, :ingest_extractor,
      provider: "openrouter",
      model: "unavailable-model",
      model_version: "1",
      prompt_version: "extract-13",
      pipeline_version: "f5-1"
    )

    # The recorded call returns an error, standing in for a vendor outage or rate limit.
    CassetteProvider.start!(@cassette, "provider_outage")
    Application.put_env(:memhouse, :model_provider, CassetteProvider)

    # The job must fail rather than "succeed with no knowledge". A swallowed provider error
    # would mark the message extracted and the observation would be silently lost forever.
    assert %{success: 0, failure: 1} = Oban.drain_queue(queue: :ingest)

    # The durable side of the outage: the message row survives, extraction is still
    # incomplete (NULL completion timestamp), the pipeline run is failed and retryable, and at least
    # one Oban job for that run is still live — not completed, discarded, or cancelled.
    assert %{rows: [[1, nil, "failed", 1, "provider_transient", queued_jobs]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(*),
                      message.extraction_completed_at,
                      run.status,
                      run.attempt_count,
                      run.last_error_class,
                      (SELECT count(*)
                       FROM oban_jobs AS job
                       WHERE job.args->'primary_key'->>'id' = run.id::text
                         AND job.state NOT IN ('completed', 'discarded', 'cancelled'))
               FROM messages AS message
               JOIN pipeline_runs AS run ON run.target_id = message.id
               WHERE message.id = $1 AND run.kind = 'extraction'
               GROUP BY message.extraction_completed_at, run.id, run.status,
                        run.attempt_count, run.last_error_class
               """,
               [Ecto.UUID.dump!(message["id"])]
             )

    assert queued_jobs >= 1

    # A failed call is still one metered event, tagged with status "error" and the provider
    # and model that failed. Operators diagnose outages from this ledger.
    assert %{rows: [[1, "error", "openrouter", "unavailable-model"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(*), min(status), min(provider), min(model_name)
               FROM usage_events
               WHERE account_id = $1 AND model_role = 'ingest_extractor'
               """,
               [Ecto.UUID.dump!(account_id)]
             )
  end

  test "the model layer scopes its own configuration read and usage write to the Account" do
    _message = seed_raw!("f5-self-scoping", "avery", "Avery prefers weekly summaries.")
    account_id = account_id!("f5-self-scoping")

    put_role!(account_id, :ingest_extractor,
      provider: "openrouter",
      model: "openai/gpt-oss-120b",
      model_version: "2026-07",
      prompt_version: "extract-13",
      pipeline_version: "f5-1"
    )

    # An actor is a plain struct naming the Account and the authorization role. It stays
    # valid after the transaction that produced it ends, which is what lets a caller resolve
    # a role and meter a call from outside one.
    actor =
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor -> actor end
      )

    # Both reads below happen with no Account transaction open, which is where the model
    # layer runs once the extraction pipeline stops holding one across the provider call.
    clear_account_settings!()

    config = Model.Config.resolve(:ingest_extractor, %{account_id: account_id, actor: actor})

    assert config.provider == "openrouter"
    assert config.model_version == "2026-07"

    # The Account setting the row-level-security policies read is back, and resolution is the
    # only thing that could have installed it: it opened its own Account transaction, whose
    # transaction-local setting outlives it under the sandbox.
    #
    # Asserting the setting rather than an empty result is deliberate. This suite connects as
    # a PostgreSQL superuser, and superusers are exempt from row-level security even where it
    # is forced, so an unscoped read here would return rows anyway and prove nothing. In
    # production the same unscoped read silently returns no row and resolution falls back to
    # the compiled defaults, stamping provenance with a provider and model that never ran.
    assert account_setting!() == account_id

    clear_account_settings!()

    assert :ok ==
             MemHouse.Model.Usage.emit(
               %{account_id: account_id, actor: actor},
               config,
               %{
                 operation: :structured,
                 status: :ok,
                 duration_ms: 12,
                 usage: %{input_tokens: 7, output_tokens: 3},
                 metadata: %{repair_attempt: 0}
               }
             )

    assert account_setting!() == account_id

    # Seeding does not invoke a model, so the emitted row is the only extractor-role call in
    # this Account.
    assert scalar!(
             """
             SELECT count(*) FROM usage_events
             WHERE account_id = $1 AND model_role = 'ingest_extractor'
             """,
             [Ecto.UUID.dump!(account_id)]
           ) == 1
  end

  # Creates the account, scope, peer, session, and raw message in one call. The message lands
  # durably without running extraction, letting each test arm its own recorded provider script
  # before the model is ever consulted.
  defp seed_raw!(account_key, peer_key, content) do
    assert {:ok, message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "#{account_key}-session",
               "scope_path" => "/f5/#{account_key}",
               "peer_key" => peer_key,
               "role" => "user",
               "content" => content
             })

    message
  end

  # Persists an active, versioned role configuration for one account. A stored record wins
  # over the runtime default, which is how a test pins the provider identity strings that
  # later show up in provenance and usage rows. Writes run under a system/pipeline actor
  # with the account set as the Ash tenant, because role configuration is account-scoped.
  defp put_role!(account_id, role, attrs) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        ModelRoleConfig
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.Changeset.for_create(
          :create,
          attrs
          |> Map.new()
          |> Map.put(:role, Atom.to_string(role))
          |> Map.put(:version, 1)
          |> Map.put(:active, true)
        )
        |> Ash.create!(actor: actor)
      end
    )
  end

  # Raw SQL on purpose: these helpers read committed rows without going through Ash
  # authorization, so an assertion cannot be satisfied by a policy-shaped read that happens
  # to hide the row. Test-only; production code never reaches the tables this way.
  defp account_id!(account_key) do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT id::text FROM accounts WHERE key = $1", [account_key])

    id
  end

  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, params)
    value
  end

  # Blanks both transaction-local settings the row-level-security policies read, reproducing
  # the state a caller is in with no Account transaction open. The policies compare against
  # `NULLIF(current_setting(...), '')`, so a blank setting matches nothing rather than raising
  # a cast error.
  #
  # Necessary because the SQL sandbox wraps each test in one transaction: a scoped block that
  # has already run leaves its setting installed for the rest of the test, which would mask
  # the condition the test above exists to reproduce.
  defp clear_account_settings! do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      SELECT set_config('memhouse.account_id', '', true),
             set_config('memhouse.account_key', '', true)
      """,
      []
    )

    :ok
  end

  # The Account currently installed for row-level security, or an empty string when none is.
  # Reading it back is how a test observes that a function opened an Account transaction of
  # its own, since the setting is transaction-local and the sandbox keeps the enclosing
  # transaction open for the whole test.
  defp account_setting!, do: scalar!("SELECT current_setting('memhouse.account_id', true)", [])
end
