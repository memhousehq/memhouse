# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Eval.Smoke do
  @moduledoc """
  Runs a small local memory smoke pass through MemHouse's real durable write/read
    path.

    Per-message keys other than `content` are optional and defaulted below. Each
    question needs `question`; `id`, `scope_path`, and `expected` are optional.
  """

  use Mix.Task

  alias MemHouse.Memory

  @shortdoc "Runs the MemHouse local memory smoke eval"

  @doc """
  Parses the switches described in the module documentation, runs the pass, and emits the
  report to standard output or `--output`.

  Raises on unusable input, a failed ingest or answer, or an unwritable output path, each
  of which surfaces as a non-zero exit status.
  """
  @impl true
  def run(args) do
    # The smoke pass goes through the ordinary domain, so the repo, model roles, and job
    # supervision must all be running before the first ingest.
    Mix.Task.run("app.start")

    # Unknown switches are deliberately tolerated here (the third element is discarded)
    # because this is a scratch command; the graded tasks reject them instead.
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          dataset: :string,
          profile: :string,
          account: :string,
          output: :string
        ]
      )

    profile = Keyword.get(opts, :profile, "balanced")
    account_key = Keyword.get(opts, :account, "eval-poc")
    dataset = load_dataset(Keyword.get(opts, :dataset))

    ingested =
      dataset["messages"]
      |> Enum.map(fn message ->
        message
        |> Map.put_new("scope_path", "/bench/smoke")
        |> Map.put_new("peer_key", "peer")
        |> Map.put_new("session_id", "smoke")
        |> Map.put_new("role", "user")
        # `put`, not `put_new`: the switch decides which Account is written to, so a
        # dataset file can never redirect a smoke run into somebody else's tenant.
        |> Map.put("account_key", account_key)
        |> then(fn attrs ->
          with {:ok, stored} <- Memory.ingest_message(attrs),
               {:ok, _knowledge} <- Memory.extract_message(stored["id"], account_key) do
            {:ok, stored}
          end
        end)
      end)

    answers =
      dataset["questions"]
      |> Enum.map(fn question ->
        result =
          Memory.ask(%{
            "account_key" => account_key,
            "scope_path" => Map.get(question, "scope_path", "/bench/smoke"),
            "question" => Map.fetch!(question, "question"),
            "profile" => profile
          })

        %{
          "id" => Map.get(question, "id"),
          "question" => Map.fetch!(question, "question"),
          "expected" => Map.get(question, "expected"),
          "answer" => result["answer"],
          "citations" => result["citations"],
          "abstained" => result["abstained"],
          "profile_version" => result["profile_version"],
          "contributed_strategies" => result["contributed_strategies"]
        }
      end)

    report = %{
      "benchmark" => Map.get(dataset, "benchmark", "smoke"),
      "profile" => profile,
      # Answers report the retrieval/context contract identity they were produced under.
      # "f7-1" is only the fallback for a dataset with no questions; bumping that string is
      # a deliberate contract change that also needs a changelog entry and fresh evidence,
      # so do not edit it to match a local experiment.
      "profile_version" => answers |> List.first(%{}) |> Map.get("profile_version", "f7-1"),
      "account_key" => account_key,
      "messages_attempted" => length(dataset["messages"]),
      "messages_ingested" => Enum.count(ingested, &match?({:ok, _}, &1)),
      "questions" => answers
    }

    encoded = Jason.encode_to_iodata!(report, pretty: true)

    case Keyword.get(opts, :output) do
      nil ->
        IO.puts(encoded)

      path ->
        File.write!(path, encoded)
        Mix.shell().info("wrote #{path}")
    end
  end

  # The built-in dataset covers the three shapes the graded benchmarks exercise — a
  # conversational preference, a factual assistant statement, and a scale claim — each in
  # its own scope so a leak across scopes shows up as a wrong or abstained answer.
  defp load_dataset(nil) do
    %{
      "benchmark" => "memhouse-poc-smoke",
      "messages" => [
        %{
          "session_id" => "locomo-smoke-1",
          "scope_path" => "/bench/locomo",
          "peer_key" => "alice",
          "role" => "user",
          "content" =>
            "Alice prefers concise status updates. Alice moved the launch review to Friday."
        },
        %{
          "session_id" => "longmemeval-smoke-1",
          "scope_path" => "/bench/longmemeval",
          "peer_key" => "sam",
          "role" => "assistant",
          "content" =>
            "Sam confirmed that the team uses OpenRouter with openai/gpt-oss-120b for POC reasoning."
        },
        %{
          "session_id" => "beam-smoke-1",
          "scope_path" => "/bench/beam",
          "peer_key" => "dev-agent",
          "role" => "assistant",
          "content" =>
            "The BEAM smoke curve starts with tiny corpora before any 1M-token or 10M-token run."
        }
      ],
      "questions" => [
        %{
          "id" => "locomo-q1",
          "scope_path" => "/bench/locomo",
          "question" => "What kind of status updates does Alice prefer?",
          "expected" => "concise"
        },
        %{
          "id" => "longmemeval-q1",
          "scope_path" => "/bench/longmemeval",
          "question" => "Which model is used for POC reasoning?",
          "expected" => "openai/gpt-oss-120b"
        },
        %{
          "id" => "beam-q1",
          "scope_path" => "/bench/beam",
          "question" => "What scale should BEAM start with?",
          "expected" => "tiny corpora"
        }
      ]
    }
  end

  defp load_dataset(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end
end
