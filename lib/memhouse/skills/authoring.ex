# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Skills.Authoring do
  @moduledoc """
  Publishes immutable skill requirement card versions.

  Cards are human-authored configuration, not governed knowledge. Publishing atomically locks the
  Account/scope/skill key, retires active versions, inserts the next version, and appends audit.

  Versions are never reused, including retired ones. Never update cards in place, expose authoring
  to machine credentials, or store statement text or secrets in cards.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Pipeline.Lock
  alias MemHouse.Skills.Selector
  alias MemHouse.Skills.SkillRequirementCard
  alias MemHouse.Topology.Scope

  require Ash.Query

  @doc """
  Publishes the next version of one skill requirement card.

  `actor` must be an authenticated actor holding an authoring role; the Account is derived from
  that identity and never from `attrs`. `attrs` may use string or atom keys and carries:

  * `"skill_key"` — the skill this card governs, as a lowercase slug. Required.
  * `"scope_id"` or `"scope_path"` — where the card is attached. Required.
  * `"requirements"` — the requirement list, which is validated and normalized before anything
    is written. Required.
  * `"description"` — optional free-text note for reviewers; blank strings become nil.

  Returns `{:ok, card}` with the newly created active version, or `{:error, message}` when the
  skill key is not a slug, the requirements do not validate, or the scope cannot be found or is
  not authorized for this actor.

  Raises `ArgumentError` when neither `"scope_id"` nor `"scope_path"` is present, and raises if
  the underlying transaction or an Ash write fails — including when the actor lacks an authoring
  role, which is an authorization failure rather than an error tuple.
  """
  def publish(actor, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    # Validate before opening the transaction: a malformed card should cost nothing and should
    # never hold the advisory lock while it is being rejected.
    with {:ok, skill_key} <- skill_key(attrs["skill_key"]),
         {:ok, requirements} <- Selector.validate_requirements(attrs["requirements"]) do
      result =
        DataLayer.with_actor(actor, fn account, current_actor ->
          case scope(account.id, current_actor, attrs) do
            nil ->
              {:error, "scope not found or not authorized"}

            scope ->
              publish_in_scope!(account.id, current_actor, scope, skill_key, requirements, attrs)
          end
        end)

      case result do
        {:error, _message} = error -> error
        card -> {:ok, card}
      end
    end
  end

  # Order is load-bearing: lock, read, retire, then insert. The transaction-scoped lock serializes
  # only publishers of the same Account/scope/skill card.
  defp publish_in_scope!(account_id, actor, scope, skill_key, requirements, attrs) do
    Lock.acquire!(account_id, "skill-card:#{scope.id}:#{skill_key}")

    existing =
      SkillRequirementCard
      |> Ash.Query.filter(scope_id == ^scope.id and skill_key == ^skill_key)
      |> Ash.Query.sort(version: :desc)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    Enum.each(Enum.filter(existing, & &1.active), fn card ->
      card
      |> Ash.Changeset.for_update(:deactivate, %{})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)
    end)

    # Include retired versions so numbers are never reused.
    next_version =
      case existing do
        [%{version: version} | _] -> version + 1
        [] -> 1
      end

    SkillRequirementCard
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:create_version, %{
      scope_id: scope.id,
      skill_key: skill_key,
      description: blank_to_nil(attrs["description"]),
      # Stamp the running grammar; callers cannot claim an unsupported version.
      requirement_schema_version: Selector.schema_version(),
      version: next_version,
      requirements: requirements,
      active: true
    })
    |> Ash.create!(actor: actor)
  end

  # Account-scoped actor reads prevent publishing to another or unauthorized scope.
  defp scope(account_id, actor, %{"scope_id" => scope_id}) when is_binary(scope_id) do
    Scope
    |> Ash.Query.filter(id == ^scope_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp scope(account_id, actor, %{"scope_path" => scope_path}) when is_binary(scope_path) do
    scope_path = normalize_path(scope_path)

    Scope
    |> Ash.Query.filter(path == ^scope_path)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp scope(_account_id, _actor, _attrs),
    do: raise(ArgumentError, "scope_id or scope_path is required")

  # Lowercase slugs keep inheritance keys stable across scopes.
  defp skill_key(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[a-z][a-z0-9]*(?:[-_][a-z0-9]+)*\z/, value) do
      {:ok, value}
    else
      {:error, "skill_key must be a lowercase slug"}
    end
  end

  defp skill_key(_value), do: {:error, "skill_key is required"}

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: to_string(value)

  # Canonical path: one leading slash, no trailing slash, root unchanged.
  defp normalize_path(path) do
    normalized = "/" <> (path |> String.trim() |> String.trim("/"))
    if normalized == "/", do: "/", else: normalized
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
