# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Adapter do
  @moduledoc """
  Normalizes supported benchmark fixtures into one internal evaluation case shape.

  Adapters preserve source ids, expected evidence, dataset identity, and split while rejecting
  malformed inputs. Normalization must be deterministic and must not leak expected answers into
  the memory query.
  """

  # The canonical names accepted by `--benchmark` and used to tag a normalized dataset.
  @benchmark_names ~w(locomo longmemeval convomem beam memhouse)

  @doc """
  Reads a benchmark fixture from disk and returns the normalized dataset plus its digest.

  `path` may hold a single JSON document (object or array) or newline-delimited JSON; the
  layout is detected from the first non-whitespace character. `opts` accepts `:benchmark`
  to pin the source format; without it the format is inferred from the data.

  On top of the normalized dataset the result carries `:dataset_id` (the file's base name)
  and `:dataset_sha256` (lowercase hex). The digest is taken over the raw file bytes
  before parsing, so it names the exact input a report was produced from — a published
  number is only checkable when that digest travels with it.

  Raises `File.Error` when the path cannot be read, and `Jason.DecodeError` when the
  contents are neither valid JSON nor valid JSON Lines.
  """
  def load!(path, opts \\ []) do
    body = read_fixture!(path)

    dataset =
      body
      |> decode_fixture!()
      |> normalize(opts)

    Map.merge(dataset, %{
      dataset_id: Path.basename(path),
      dataset_sha256:
        body
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    })
  end

  @doc """
  Rewrites already-decoded fixture data into the normalized dataset shape.

  `data` is the decoded fixture: a map for single-sample layouts, or a list for the
  multi-sample and JSON-Lines layouts. `opts[:benchmark]` pins the source format. It
  accepts an atom or a string, is matched after downcasing and stripping every character
  that is not a letter, and additionally treats `"longmemevalv2"` as LongMemEval and
  `"local"` as the MemHouse shape.

  When `:benchmark` is absent — or names something unrecognized — the layout is inferred
  from marker fields in the data itself, and anything matching no other layout is parsed
  as BEAM. An unknown name therefore falls back to detection instead of raising, so pass a
  supported name whenever the parse needs to be pinned.

  Returns the normalized dataset without `:dataset_id` and `:dataset_sha256`; those exist
  only on datasets that came from a file through `load!/2`. Raises `KeyError` when a
  record omits something its layout requires, such as a question's text or a LoCoMo
  sample's conversation.
  """
  def normalize(data, opts \\ []) do
    benchmark =
      opts
      |> Keyword.get(:benchmark)
      |> normalize_benchmark()
      |> case do
        nil -> detect_benchmark(data)
        benchmark -> benchmark
      end

    case benchmark do
      "locomo" -> normalize_locomo(data)
      "longmemeval" -> normalize_longmemeval(data)
      "convomem" -> normalize_convomem(data)
      "beam" -> normalize_beam(data)
      "memhouse" -> normalize_memhouse(data)
    end
  end

  # Benchmark fixture paths come from the local Mix task, not from a web request.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_fixture!(path), do: File.read!(path)

  # Upstream benchmark releases ship both single-document JSON and one-record-per-line
  # JSON Lines, sometimes with the same file extension, so the layout is sniffed from the
  # first non-whitespace character rather than from the name.
  defp decode_fixture!(body) do
    trimmed = String.trim(body)

    if String.starts_with?(trimmed, ["[", "{"]) do
      Jason.decode!(body)
    else
      trimmed
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end
  end

  # Returns a canonical benchmark name, or nil so the caller can fall back to detection.
  defp normalize_benchmark(nil), do: nil

  defp normalize_benchmark(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_benchmark()

  defp normalize_benchmark(value) when is_binary(value) do
    value = value |> String.downcase() |> String.replace(~r/[^a-z]/, "")

    cond do
      value in @benchmark_names -> value
      value == "longmemevalv2" -> "longmemeval"
      value == "local" -> "memhouse"
      true -> nil
    end
  end

  # Layout inference. Clause order is the rule, not an accident: a self-declared
  # "benchmark" field wins, then structural marker fields, and BEAM is the catch-all
  # because its generated artifacts have no field that is reliably present. Adding a
  # clause below the catch-all would be dead code.
  defp detect_benchmark(%{"benchmark" => benchmark} = data) do
    # An unrecognized self-declared name is dropped and detection retried structurally.
    normalize_benchmark(benchmark) || detect_benchmark(Map.delete(data, "benchmark"))
  end

  defp detect_benchmark(%{"messages" => messages, "questions" => questions})
       when is_list(messages) and is_list(questions),
       do: "memhouse"

  defp detect_benchmark([first | _]) when is_map(first) do
    cond do
      Map.has_key?(first, "conversation") and Map.has_key?(first, "qa") -> "locomo"
      Map.has_key?(first, "haystack_sessions") -> "longmemeval"
      Map.has_key?(first, "conversations") and Map.has_key?(first, "question") -> "convomem"
      true -> "beam"
    end
  end

  defp detect_benchmark(%{"haystack_sessions" => _}), do: "longmemeval"
  defp detect_benchmark(%{"conversation" => _, "qa" => _}), do: "locomo"
  defp detect_benchmark(%{"conversations" => _, "question" => _}), do: "convomem"
  defp detect_benchmark(_data), do: "beam"

  # MemHouse's own smoke shape: one flat message list and one question list, treated as a
  # single case. A JSON-Lines file of the same shape becomes one case per line.
  defp normalize_memhouse(%{"messages" => messages, "questions" => questions} = data) do
    benchmark = Map.get(data, "benchmark", "memhouse")
    case_id = Map.get(data, "id", benchmark)

    %{
      benchmark: benchmark,
      source_format: "memhouse",
      cases: [
        %{
          id: to_string(case_id),
          scope_path: "/bench/#{benchmark}/#{slug(case_id)}",
          category: nil,
          scale: nil,
          metadata: Map.get(data, "metadata", %{}),
          messages: Enum.map(messages, &normalize_memhouse_message(&1, case_id)),
          questions: Enum.map(questions, &normalize_memhouse_question(&1, case_id))
        }
      ]
    }
  end

  defp normalize_memhouse(data) when is_list(data) do
    %{
      benchmark: "memhouse",
      source_format: "memhouse-jsonl",
      cases:
        data
        |> Enum.with_index(1)
        |> Enum.map(fn {item, index} ->
          normalize_memhouse(Map.put_new(item, "id", "case-#{index}")).cases |> hd()
        end)
    }
  end

  defp normalize_memhouse_message(message, case_id) do
    # A fixture without ids still needs a stable citation reference, so the fallback id is
    # content-derived. Using the list position instead would silently renumber every later
    # turn when one message is inserted, invalidating recorded evidence references.
    id =
      message
      |> first_present(["id", "message_id", "benchmark_ref"])
      |> default_to("#{case_id}:message:#{stable_hash(message)}")

    %{
      id: to_string(id),
      session_id: message |> Map.get("session_id", "#{case_id}-session") |> to_string(),
      scope_path: Map.get(message, "scope_path"),
      peer_key: message |> Map.get("peer_key", "peer") |> to_string(),
      role: message |> Map.get("role", "user") |> normalize_role(),
      content: message |> Map.fetch!("content") |> to_string(),
      occurred_at: Map.get(message, "occurred_at"),
      metadata: Map.get(message, "metadata", %{})
    }
  end

  defp normalize_memhouse_question(question, case_id) do
    id = question |> Map.get("id", "#{case_id}:question:#{stable_hash(question)}") |> to_string()
    evidence_refs = listify(Map.get(question, "evidence") || Map.get(question, "evidence_refs"))

    %{
      id: id,
      scope_path: Map.get(question, "scope_path"),
      question: question |> Map.fetch!("question") |> to_string(),
      expected: expected_values(question),
      category:
        question |> first_present(["category", "question_type", "ability"]) |> maybe_string(),
      evidence_refs: Enum.map(evidence_refs, &to_string/1),
      evidence_granularity: Map.get(question, "evidence_granularity", "turn"),
      abstention_expected: abstention_expected?(question),
      metadata: Map.get(question, "metadata", %{})
    }
  end

  # LoCoMo ships one or many long multi-session conversations between two named speakers.
  # Every sample becomes one case, tagged with the "long-conversation" scale so aggregate
  # reporting can separate it from the short-context benchmarks.
  defp normalize_locomo(data) when is_map(data), do: normalize_locomo([data])

  defp normalize_locomo(samples) when is_list(samples) do
    %{
      benchmark: "locomo",
      source_format: "locomo10",
      cases:
        samples
        |> Enum.with_index(1)
        |> Enum.map(fn {sample, index} ->
          case_id = sample |> Map.get("sample_id", "locomo-#{index}") |> to_string()
          conversation = Map.fetch!(sample, "conversation")

          %{
            id: case_id,
            scope_path: "/bench/locomo/#{slug(case_id)}",
            category: nil,
            scale: "long-conversation",
            metadata: %{
              "speaker_a" => conversation["speaker_a"],
              "speaker_b" => conversation["speaker_b"]
            },
            messages: locomo_messages(conversation, case_id),
            questions: locomo_questions(Map.get(sample, "qa", []), case_id)
          }
        end)
    }
  end

  # A LoCoMo conversation is a map whose session turns hide behind "session_<n>" keys,
  # alongside sibling "session_<n>_date_time" keys and speaker metadata. Everything that
  # is not a numbered session list is skipped rather than treated as dialogue.
  defp locomo_messages(conversation, case_id) do
    conversation
    |> Enum.flat_map(fn
      {"session_" <> suffix = key, turns} when is_list(turns) ->
        case Integer.parse(suffix) do
          {session_number, ""} ->
            date = Map.get(conversation, "#{key}_date_time")
            session_id = "#{case_id}-session-#{session_number}"

            turns
            |> Enum.with_index(1)
            |> Enum.map(fn {turn, index} ->
              speaker = Map.get(turn, "speaker", "speaker")
              dia_id = turn |> Map.get("dia_id", "D#{session_number}:#{index}") |> to_string()

              %{
                id: dia_id,
                session_id: session_id,
                scope_path: nil,
                peer_key: slug(speaker),
                role: locomo_role(speaker, conversation),
                content: locomo_content(turn),
                occurred_at: date,
                metadata: %{
                  "dia_id" => dia_id,
                  "speaker" => speaker,
                  "session_number" => session_number
                }
              }
            end)

          _invalid_session_key ->
            []
        end

      _other ->
        []
    end)
    # Map iteration order is undefined, so "session_10" can arrive before "session_2" and
    # turns would be ingested out of order. Memory is order- and time-sensitive, so sort
    # numerically on the dialogue id's (session, turn) pair before returning.
    |> Enum.sort_by(fn message ->
      message.metadata["dia_id"]
      |> String.replace_leading("D", "")
      |> String.split(":")
      |> Enum.map(&parse_int(&1, 0))
    end)
  end

  # LoCoMo turns may carry an image with a caption. The caption is appended to the text so
  # the evidence a question depends on is actually present in the ingested content.
  defp locomo_content(turn) do
    text = turn |> Map.get("text", "") |> to_string()

    case Map.get(turn, "blip_caption") do
      caption when is_binary(caption) and caption != "" -> "#{text}\nImage caption: #{caption}"
      _caption -> text
    end
  end

  # LoCoMo is speaker-to-speaker rather than user-to-assistant. The first named speaker is
  # mapped to "user" and everyone else to "assistant" purely so the ingest path sees a
  # shape it understands; the real identity is preserved in the peer key and metadata.
  defp locomo_role(speaker, %{"speaker_a" => speaker}), do: "user"
  defp locomo_role(_speaker, _conversation), do: "assistant"

  defp locomo_questions(questions, case_id) do
    questions
    |> Enum.with_index(1)
    |> Enum.map(fn {question, index} ->
      %{
        id: question |> Map.get("id", "#{case_id}-qa-#{index}") |> to_string(),
        scope_path: nil,
        question: question |> Map.fetch!("question") |> to_string(),
        expected: expected_values(question),
        category: question |> Map.get("category") |> maybe_string(),
        evidence_refs: question |> Map.get("evidence", []) |> listify() |> Enum.map(&to_string/1),
        evidence_granularity: "turn",
        abstention_expected: abstention_expected?(question),
        metadata: Map.drop(question, ["question", "answer", "evidence"])
      }
    end)
  end

  # LongMemEval instances are question-centric: each one bundles a single question with a
  # haystack of sessions it must be answered from, so a case here holds exactly one
  # question. Evidence is labelled by session, not by turn.
  defp normalize_longmemeval(data) when is_map(data), do: normalize_longmemeval([data])

  defp normalize_longmemeval(instances) when is_list(instances) do
    %{
      benchmark: "longmemeval",
      source_format: "longmemeval-cleaned",
      cases:
        instances
        |> Enum.with_index(1)
        |> Enum.map(fn {instance, index} ->
          question_id = instance |> Map.get("question_id", "longmemeval-#{index}") |> to_string()
          category = longmemeval_category(instance)

          %{
            id: question_id,
            scope_path: "/bench/longmemeval/#{slug(question_id)}",
            category: category,
            scale: longmemeval_scale(instance),
            metadata:
              Map.take(instance, ["question_date", "haystack_session_ids", "answer_session_ids"]),
            messages: longmemeval_messages(instance, question_id),
            questions: [
              %{
                id: question_id,
                scope_path: nil,
                question: instance |> Map.fetch!("question") |> to_string(),
                expected: expected_values(instance),
                category: category,
                evidence_refs:
                  instance
                  |> Map.get("answer_session_ids", [])
                  |> listify()
                  |> Enum.map(&to_string/1),
                evidence_granularity: "session",
                abstention_expected: category == "abstention" or abstention_expected?(instance),
                metadata: Map.take(instance, ["question_date"])
              }
            ]
          }
        end)
    }
  end

  # Sessions, their ids, and their dates arrive as three parallel lists that are joined by
  # position. A short or missing id/date list is tolerated: the position simply falls back
  # to a synthetic session id and an unknown timestamp.
  defp longmemeval_messages(instance, question_id) do
    session_ids = Map.get(instance, "haystack_session_ids", [])
    dates = Map.get(instance, "haystack_dates", [])

    instance
    |> Map.get("haystack_sessions", [])
    |> Enum.with_index()
    |> Enum.flat_map(fn {session, session_index} ->
      session_id =
        session_ids
        |> Enum.at(session_index, "#{question_id}-session-#{session_index + 1}")
        |> to_string()

      occurred_at = Enum.at(dates, session_index)

      session
      |> Enum.with_index(1)
      |> Enum.map(fn {turn, turn_index} ->
        role = turn |> Map.get("role", "user") |> normalize_role()

        %{
          id: "#{session_id}:#{turn_index}",
          session_id: "#{question_id}-#{session_id}",
          scope_path: nil,
          peer_key: role,
          role: role,
          content: turn |> Map.get("content", "") |> to_string(),
          occurred_at: occurred_at,
          metadata: %{"source_session_id" => session_id, "turn_index" => turn_index}
        }
      end)
    end)
  end

  defp longmemeval_category(instance) do
    if longmemeval_abstention_id?(instance) do
      "abstention"
    else
      case Map.get(instance, "question_type") do
        nil -> nil
        value -> to_string(value)
      end
    end
  end

  # LongMemEval marks its unanswerable variants by suffixing the question id with "_abs".
  # Detecting them here is what makes a refusal score as correct instead of as a miss.
  defp longmemeval_abstention_id?(%{"question_id" => id}) when is_binary(id),
    do: String.ends_with?(id, "_abs")

  defp longmemeval_abstention_id?(_instance), do: false

  # LongMemEval publishes a small and a medium haystack of the same questions; the medium
  # one holds roughly 500 sessions per instance against roughly 50 for the small one. The
  # 400-session cut sits in that gap, so a full instance is labelled by which release it
  # came from and degradation with corpus size stays visible in the by-scale aggregate. A
  # truncated local fixture falls under the cut and is reported as small.
  defp longmemeval_scale(instance) do
    count = instance |> Map.get("haystack_sessions", []) |> length()

    cond do
      count >= 400 -> "m"
      count > 0 -> "s"
      true -> nil
    end
  end

  # ConvoMem rows are also question-centric: one question over a list of prior
  # conversations. The scale label is the conversation count as a string, so the by-scale
  # aggregate shows how accuracy moves with how much history had to be searched.
  defp normalize_convomem(data) when is_map(data) do
    rows =
      cond do
        is_list(data["data"]) -> data["data"]
        is_list(data["questions"]) -> data["questions"]
        true -> [data]
      end

    normalize_convomem(rows)
  end

  defp normalize_convomem(rows) when is_list(rows) do
    %{
      benchmark: "convomem",
      source_format: "convomem",
      cases:
        rows
        |> Enum.with_index(1)
        |> Enum.map(fn {row, index} ->
          case_id =
            row
            |> first_present(["id", "question_id", "sample_id"])
            |> default_to("convomem-#{index}")
            |> to_string()

          category =
            row
            |> first_present(["category", "question_type", "type"])
            |> maybe_string()

          conversations =
            row
            |> first_present(["conversations", "conversation_history", "history", "messages"])
            |> listify()

          %{
            id: case_id,
            scope_path: "/bench/convomem/#{slug(case_id)}",
            category: category,
            scale: conversations |> length() |> Integer.to_string(),
            metadata: Map.take(row, ["split", "category", "question_type"]),
            messages: convomem_messages(conversations, case_id),
            questions: [
              %{
                id: case_id,
                scope_path: nil,
                question: row |> Map.fetch!("question") |> to_string(),
                expected: expected_values(row),
                category: category,
                evidence_refs:
                  row
                  |> first_present(["evidence", "evidence_ids", "supporting_message_ids"])
                  |> listify()
                  |> Enum.map(&to_string/1),
                evidence_granularity: "turn",
                abstention_expected:
                  category in ["abstention", "unanswerable"] or abstention_expected?(row),
                metadata: Map.take(row, ["split"])
              }
            ]
          }
        end)
    }
  end

  defp convomem_messages(conversations, case_id) do
    conversations
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {conversation, conversation_index} ->
      if is_map(conversation) do
        session_id =
          conversation
          |> first_present(["id", "conversation_id", "session_id"])
          |> default_to("#{case_id}-conversation-#{conversation_index}")
          |> to_string()

        case first_present(conversation, ["messages", "turns", "conversation"]) do
          turns when is_list(turns) ->
            convomem_turns(turns, case_id, session_id)

          # Some exports flatten a one-turn conversation into the conversation object
          # itself; treat that object as its own single turn rather than dropping it.
          _turns ->
            convomem_turns([conversation], case_id, session_id)
        end
      else
        []
      end
    end)
  end

  defp convomem_turns(turns, case_id, session_id) do
    turns
    |> Enum.with_index(1)
    |> Enum.map(fn {turn, index} ->
      role = turn |> first_present(["role", "speaker"]) |> default_to("user") |> normalize_role()

      id =
        turn
        |> first_present(["id", "message_id", "turn_id"])
        |> default_to("#{session_id}:#{index}")
        |> to_string()

      %{
        id: id,
        session_id: "#{case_id}-#{session_id}",
        scope_path: nil,
        peer_key: role,
        role: role,
        content:
          turn
          |> first_present(["content", "text", "message"])
          |> default_to("")
          |> to_string(),
        occurred_at: first_present(turn, ["occurred_at", "timestamp", "date"]),
        metadata: %{"source_session_id" => session_id, "turn_index" => index}
      }
    end)
  end

  # BEAM-style fixtures are generated artifacts with no single stable schema, so every
  # field is looked up through a list of plausible names and the whole layout is the
  # detection catch-all. Its cases pair one long chat with a set of probing questions, and
  # the chat's declared size becomes the scale label that the degradation curve groups by.
  defp normalize_beam(data) when is_map(data) do
    cond do
      is_list(data["chats"]) -> normalize_beam(data["chats"])
      is_list(data["conversations"]) -> normalize_beam(data["conversations"])
      is_list(data["data"]) -> normalize_beam(data["data"])
      true -> normalize_beam([data])
    end
  end

  defp normalize_beam(chats) when is_list(chats) do
    %{
      benchmark: "beam",
      source_format: "beam",
      cases:
        chats
        |> Enum.with_index(1)
        |> Enum.map(fn {chat, index} ->
          case_id = beam_case_id(chat, index)

          %{
            id: case_id,
            scope_path: "/bench/beam/#{slug(case_id)}",
            category: nil,
            scale: beam_scale(chat),
            metadata: Map.take(chat, ["chat_size", "scale", "domain", "topic"]),
            messages: beam_messages(chat, case_id),
            questions: beam_questions(chat, case_id)
          }
        end)
    }
  end

  defp beam_case_id(chat, index) do
    chat
    |> first_present(["chat_id", "conversation_id", "id", "sample_id"])
    |> default_to("beam-#{index}")
    |> to_string()
  end

  defp beam_messages(chat, case_id) do
    chat
    |> first_present(["conversation", "messages", "chat", "dialogue", "turns"])
    |> listify()
    |> Enum.with_index(1)
    |> Enum.map(fn {turn, index} ->
      # Generated chats often omit roles entirely. Assume strict alternation starting with
      # the user, which matches how these transcripts are produced.
      role =
        turn
        |> first_present(["role", "speaker"])
        |> default_to(if(rem(index, 2) == 1, do: "user", else: "assistant"))
        |> normalize_role()

      turn_id =
        turn
        |> first_present(["id", "turn_id", "message_id", "dia_id"])
        |> default_to("#{case_id}:turn:#{index}")
        |> to_string()

      %{
        id: turn_id,
        session_id: case_id,
        scope_path: nil,
        peer_key: role,
        role: role,
        content:
          turn
          |> first_present(["content", "text", "message", "utterance", "answer"])
          |> default_to("")
          |> to_string(),
        occurred_at: first_present(turn, ["timestamp", "date", "created_at"]),
        metadata: %{"turn_index" => index}
      }
    end)
    # An empty turn would still consume an ingest round trip and a raw-message row while
    # contributing nothing retrievable, so drop it before it reaches the write path.
    |> Enum.reject(&(&1.content == ""))
  end

  defp beam_questions(chat, case_id) do
    chat
    |> first_present(["probing_questions", "questions", "qa"])
    |> listify()
    |> Enum.with_index(1)
    |> Enum.map(fn {question, index} ->
      %{
        id:
          question
          |> first_present(["question_id", "id"])
          |> default_to("#{case_id}:question:#{index}")
          |> to_string(),
        scope_path: nil,
        question: question |> Map.fetch!("question") |> to_string(),
        expected: expected_values(question),
        category:
          question
          |> first_present(["ability", "category", "question_type", "type"])
          |> maybe_string(),
        evidence_refs: beam_evidence_refs(question),
        evidence_granularity: "turn",
        abstention_expected: abstention_expected?(question),
        metadata: Map.take(question, ["difficulty", "rubric", "chat_size", "scale"])
      }
    end)
  end

  # Evidence may be given as bare turn ids or as objects wrapping one; both are flattened
  # to plain strings so citation scoring compares like with like.
  defp beam_evidence_refs(question) do
    question
    |> first_present([
      "evidence",
      "evidence_refs",
      "evidence_turns",
      "evidence_ids",
      "source_turn_ids"
    ])
    |> listify()
    |> Enum.flat_map(fn
      value when is_map(value) ->
        value
        |> first_present(["id", "turn_id", "message_id", "dia_id"])
        |> listify()

      value ->
        [value]
    end)
    |> Enum.map(&to_string/1)
  end

  defp beam_scale(chat) do
    chat
    |> first_present(["chat_size", "scale", "token_size", "size"])
    |> maybe_string()
  end

  # Gold answers are always normalized to a list of strings, even when a fixture gives a
  # single value, because scoring credits an answer that matches any accepted variant.
  defp expected_values(map) do
    map
    |> first_present([
      "answer",
      "expected",
      "expected_answer",
      "golden_answer",
      "reference_answer",
      "target"
    ])
    |> listify()
    |> Enum.map(&to_string/1)
  end

  # A question is unanswerable when the fixture says so outright, when its category names
  # abstention, or when its gold answer is one of the fixed refusal strings the upstream
  # datasets use. The string list is a closed set on purpose: a fuzzy match would turn a
  # genuine answer such as "unknown soldier" into an expected refusal.
  defp abstention_expected?(map) do
    expected = expected_values(map) |> Enum.map(&String.downcase/1)

    category =
      map |> first_present(["category", "question_type", "ability", "type"]) |> maybe_string()

    Map.get(map, "abstention_expected", false) == true or
      category == "abstention" or
      Enum.any?(
        expected,
        &(&1 in [
            "not answerable",
            "no information available.",
            "no information available",
            "unknown"
          ])
      )
  end

  # Returns the first key whose value is neither nil nor "". Fixtures routinely carry an
  # empty string where a field is absent, so blank must count as missing for the fallback
  # chains above to reach the next candidate name.
  defp first_present(nil, _keys), do: nil

  defp first_present(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp listify(nil), do: []
  defp listify(value) when is_list(value), do: value
  defp listify(value), do: [value]

  defp default_to(nil, default), do: default
  defp default_to("", default), do: default
  defp default_to(value, _default), do: value

  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)

  # Collapses arbitrary speaker labels onto "assistant", "system", "tool", or "user".
  # Anything unrecognized becomes "user" rather than failing, because benchmark speaker
  # names are free text and dropping the turn would silently remove evidence.
  defp normalize_role(role) when is_binary(role) do
    case String.downcase(role) do
      "assistant" -> "assistant"
      "system" -> "system"
      "tool" -> "tool"
      _other -> "user"
    end
  end

  defp normalize_role(_role), do: "user"

  # Case ids become scope path segments, so they are reduced to lowercase alphanumerics
  # and dashes. An id that reduces to nothing still needs a segment, hence "case".
  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "case"
      slug -> slug
    end
  end

  # Content-derived suffix for records that arrive without an id. Truncated to 12 hex
  # characters (48 bits) purely for readability in reports; this is a collision-tolerant
  # label inside one fixture, not a security or global-uniqueness claim.
  defp stable_hash(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  # Lenient integer parse used for sort keys only; a malformed segment sorts as the
  # default rather than crashing a whole fixture load.
  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_value, default), do: default
end
