# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Documents.Connector do
  @moduledoc """
  Contract for replay-safe incremental document connectors.

  Adapters fetch whole raw items and the next cursor; they never write documents, chunks, or
  knowledge. Cursors must tolerate replay because the service saves them only after the page.
  Never log bytes or metadata, or resolve secrets into cursors or settings.
  """

  @typedoc """
  One item from a source page.

  `:external_id` is the source's own stable identifier and is required; it is how repeated syncs
  recognise the same document. `:bytes` is required for a live item and must be the complete
  current payload. `:deleted?` marks a removal at the source, in which case `:bytes` is not
  read and the document is tombstoned rather than erased. `:title`, `:media_type`,
  `:source_uri`, `:metadata`, and `:occurred_at` are optional descriptive fields; the title
  falls back to the external id and the media type to a generic binary type.
  """
  @type item :: %{
          required(:external_id) => String.t(),
          optional(:title) => String.t(),
          optional(:media_type) => String.t(),
          optional(:bytes) => binary(),
          optional(:source_uri) => String.t(),
          optional(:metadata) => map(),
          optional(:deleted?) => boolean(),
          optional(:occurred_at) => DateTime.t()
        }

  @typedoc """
  One page of results.

  `:items` may be empty. `:cursor` is the adapter-defined resume point that follows this page
  and is stored verbatim on the connector once the page has been durably handled. `:has_more?`
  asks the service to schedule an immediate follow-up run instead of waiting for the next
  interval.
  """
  @type page :: %{
          required(:items) => [item()],
          required(:cursor) => map(),
          optional(:has_more?) => boolean()
        }

  @doc """
  Fetches the items following `cursor` for this connector.

  Receives the prior cursor or `%{}`. Returns `{:ok, page}` or `{:error, reason}`; failures leave
  the cursor unchanged for replay.
  """
  @callback pull(MemHouse.Documents.ConnectorConfig.t(), map()) ::
              {:ok, page()} | {:error, term()}

  @doc """
  Looks up the adapter module registered for a connector kind.

  Adapters are registered per deployment in application configuration; none ship enabled, so an
  installation only syncs the sources its operator deliberately wired up.

  Raises `ArgumentError` when the kind has no registered adapter. A connector row can outlive
  the adapter that served it — after a configuration change or a downgrade — and this is how
  that shows up, at sync time rather than silently doing nothing.
  """
  def adapter!(kind) when is_binary(kind) do
    adapters =
      :memhouse
      |> Application.fetch_env!(:documents)
      |> Keyword.fetch!(:connector_adapters)

    Map.get(adapters, kind) ||
      raise ArgumentError, "connector adapter is not configured for #{inspect(kind)}"
  end
end
