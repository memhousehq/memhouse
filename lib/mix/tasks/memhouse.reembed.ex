# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Reembed do
  @moduledoc """
  Enqueues or inspects the resumable Account-wide embedding transition.

  With no options, the task uses the configured embedder identity and prints
  the durable run as JSON. `--status RUN_ID` prints its current phase, cursor,
  counts, status, and error class without exposing content.
  """

  use Mix.Task

  @shortdoc "Enqueue or inspect the embedding transition"
  @switches [status: :string]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] or rest != [] do
      Mix.raise("usage: mix memhouse.reembed [--status RUN_ID]")
    end

    Mix.Task.run("app.start")

    result =
      MemHouse.DataLayer.with_existing_free_account(fn account, actor ->
        case Keyword.get(opts, :status) do
          nil -> enqueue(account, actor)
          id -> status(account, actor, id)
        end
      end)

    Mix.shell().info(Jason.encode!(result))
  end

  defp enqueue(account, actor) do
    config = MemHouse.Model.Config.resolve(:embedder, %{account_id: account.id, actor: actor})

    identity =
      MemHouse.Model.Config.embedding_identity(config)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    {:ok, run} = MemHouse.Pipeline.enqueue_reembed(account.id, identity, actor)
    summary(run)
  end

  defp status(account, actor, id) do
    run = Ash.get!(MemHouse.Operations.PipelineRun, id, tenant: account.id, actor: actor)

    if run.kind != "reembed" do
      Mix.raise("pipeline run is not a re-embed operation")
    end

    summary(run)
  end

  defp summary(run) do
    %{
      id: run.id,
      status: run.status,
      attempt_count: run.attempt_count,
      last_error_class: run.last_error_class,
      progress: run.payload
    }
  end
end
