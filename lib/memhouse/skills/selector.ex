# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Skills.Selector do
  @moduledoc """
  Validates and normalizes the declarative skill-requirement language.

  Requirements define a `key`, metadata `selector`, blocking `level`, and `source_policy`, with
  optional freshness and prompt. Selectors never inspect text or invoke a model.

  Canonicalization expands scalars to lists, defaults `subject` to `"either"`, removes absent
  clauses, and synthesizes prompts. Stored values must already equal this canonical form.
  `required` gaps block; `preferred` gaps warn. `ask-peer` requires the checked peer's message;
  `from-memory` and `either` accept governed sources. Disabled requirements tombstone inherited
  keys.
  """

  # Stored selector contract; changing it requires migration and a documented transition.
  @schema_version "f9-1"

  # Missing `required` knowledge blocks; `preferred` only warns.
  @levels ~w(required preferred)

  # `ask-peer` requires peer authorship; `from-memory` never prompts.
  @source_policies ~w(from-memory ask-peer either)

  # Closed vocabularies reject typos instead of creating permanent unexplained gaps.
  @kinds ~w(fact preference event relation skill)
  @subjects ~w(peer scope either)
  @sensitivities ~w(public internal personal restricted)
  @target_levels ~w(peer scope account)
  @source_types ~w(message document)
  @verification_states ~w(
    pending pending_human auto_verified peer_verified curator_verified stale
  )

  # Unknown keys fail because ignoring a typo would silently weaken the requirement.
  @requirement_keys ~w(
    key description selector level source_policy freshness prompt enabled
  )
  @selector_keys ~w(
    kind subject sensitivity target_level source_types verification
    minimum_confidence minimum_corroboration
  )
  @freshness_keys ~w(revalidated_within_seconds)

  @doc """
  Returns the version identity of the selector language this build implements.

  Published cards must carry this compatibility identity.
  """
  def schema_version, do: @schema_version

  @doc """
  Validates and normalizes a whole requirement list.

  Returns `{:ok, normalized}` in input order or the first `{:error, message}`.

  Rejects duplicate keys across the list: a key identifies a requirement for inheritance and
  override, so two requirements sharing one within a single card would make the effective
  contract depend on evaluation order.

  A non-list argument is an error, not a crash.
  """
  def validate_requirements(requirements) when is_list(requirements) do
    requirements
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {requirement, index},
                                                     {:ok, normalized, keys} ->
      case normalize_requirement(requirement, index) do
        {:ok, %{"key" => key} = value} ->
          if MapSet.member?(keys, key) do
            {:halt, {:error, "requirement #{index} duplicates key #{inspect(key)}"}}
          else
            {:cont, {:ok, [value | normalized], MapSet.put(keys, key)}}
          end

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, normalized, _keys} -> {:ok, Enum.reverse(normalized)}
      {:error, _message} = error -> error
    end
  end

  def validate_requirements(_requirements), do: {:error, "requirements must be a list"}

  @doc """
  Validates and normalizes one requirement map.

  Accepts string or atom keys. `index` is used only in errors.

  Returns `{:ok, normalized}` or `{:error, message}`. Disabled requirements retain only their key
  and flag because they remove inherited keys.

  Enabled requirements come back with every optional selector field either normalized or
  removed, `subject` defaulted to `"either"`, and a `prompt` synthesized from the description or
  the key when the author supplied none.
  """
  def normalize_requirement(requirement, index \\ 0)

  def normalize_requirement(requirement, index) when is_map(requirement) do
    requirement = stringify_keys(requirement)

    with :ok <- reject_unknown(requirement, @requirement_keys, "requirement #{index}"),
         {:ok, key} <- slug(requirement["key"], "requirement #{index} key"),
         {:ok, enabled} <- boolean(Map.get(requirement, "enabled", true), key) do
      if enabled do
        normalize_enabled_requirement(requirement, key)
      else
        {:ok, %{"key" => key, "enabled" => false}}
      end
    end
  end

  def normalize_requirement(_requirement, index),
    do: {:error, "requirement #{index} must be an object"}

  # Enabled requirements have a fixed shape; an omitted selector becomes subject `either`.
  defp normalize_enabled_requirement(requirement, key) do
    with {:ok, level} <- member(requirement["level"], @levels, "requirement #{key} level"),
         {:ok, source_policy} <-
           member(
             requirement["source_policy"],
             @source_policies,
             "requirement #{key} source_policy"
           ),
         {:ok, selector} <- normalize_selector(requirement["selector"] || %{}, key),
         {:ok, freshness} <- normalize_freshness(requirement["freshness"], key) do
      description = optional_string(requirement["description"])

      prompt =
        requirement["prompt"]
        |> optional_string()
        |> default_prompt(description, key)

      {:ok,
       %{
         "key" => key,
         "description" => description,
         "selector" => selector,
         "level" => level,
         "source_policy" => source_policy,
         "freshness" => freshness,
         "prompt" => prompt,
         "enabled" => true
       }}
    end
  end

  # Remove absent clauses except required, defaulted `subject`.
  defp normalize_selector(selector, key) when is_map(selector) do
    selector = stringify_keys(selector)

    with :ok <- reject_unknown(selector, @selector_keys, "requirement #{key} selector"),
         {:ok, kinds} <- members(selector["kind"], @kinds, "requirement #{key} kind"),
         {:ok, subject} <-
           optional_member(selector["subject"], @subjects, "either", "requirement #{key} subject"),
         {:ok, sensitivities} <-
           members(
             selector["sensitivity"],
             @sensitivities,
             "requirement #{key} sensitivity"
           ),
         {:ok, target_levels} <-
           members(
             selector["target_level"],
             @target_levels,
             "requirement #{key} target_level"
           ),
         {:ok, source_types} <-
           members(selector["source_types"], @source_types, "requirement #{key} source_types"),
         {:ok, verification} <-
           members(
             selector["verification"],
             @verification_states,
             "requirement #{key} verification"
           ),
         # Confidence is a probability-like fraction from 0.0 through 1.0.
         {:ok, minimum_confidence} <-
           bounded_number(
             selector["minimum_confidence"],
             0.0,
             1.0,
             "requirement #{key} minimum_confidence"
           ),
         {:ok, minimum_corroboration} <-
           positive_integer(
             selector["minimum_corroboration"],
             "requirement #{key} minimum_corroboration"
           ) do
      {:ok,
       compact(%{
         "kind" => kinds,
         "subject" => subject,
         "sensitivity" => sensitivities,
         "target_level" => target_levels,
         "source_types" => source_types,
         "verification" => verification,
         "minimum_confidence" => minimum_confidence,
         "minimum_corroboration" => minimum_corroboration
       })}
    end
  end

  defp normalize_selector(_selector, key),
    do: {:error, "requirement #{key} selector must be an object"}

  # An explicit freshness block requires a positive window in seconds.
  defp normalize_freshness(nil, _key), do: {:ok, nil}

  defp normalize_freshness(freshness, key) when is_map(freshness) do
    freshness = stringify_keys(freshness)

    with :ok <- reject_unknown(freshness, @freshness_keys, "requirement #{key} freshness"),
         {:ok, seconds} <-
           positive_integer(
             freshness["revalidated_within_seconds"],
             "requirement #{key} revalidated_within_seconds",
             required?: true
           ) do
      {:ok, %{"revalidated_within_seconds" => seconds}}
    end
  end

  defp normalize_freshness(_freshness, key),
    do: {:error, "requirement #{key} freshness must be an object"}

  # Reject unknown keys rather than weakening the reviewed requirement.
  defp reject_unknown(map, allowed, label) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, "#{label} has unknown keys: #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  # Lowercase slugs keep inheritance keys stable across scopes.
  defp slug(value, label) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[a-z][a-z0-9]*(?:[-_][a-z0-9]+)*\z/, value) do
      {:ok, value}
    else
      {:error, "#{label} must be a lowercase slug"}
    end
  end

  defp slug(_value, label), do: {:error, "#{label} is required"}

  defp member(value, allowed, label) do
    if value in allowed do
      {:ok, value}
    else
      {:error, "#{label} must be one of #{inspect(allowed)}"}
    end
  end

  defp optional_member(nil, _allowed, default, _label), do: {:ok, default}
  defp optional_member(value, allowed, _default, label), do: member(value, allowed, label)

  # Normalize scalars to lists; reject empty lists as unsatisfiable.
  defp members(nil, _allowed, _label), do: {:ok, nil}

  defp members(value, allowed, label) do
    values = if is_list(value), do: value, else: [value]

    if values != [] and Enum.all?(values, &(&1 in allowed)) do
      {:ok, Enum.uniq(values)}
    else
      {:error, "#{label} must contain only #{inspect(allowed)}"}
    end
  end

  # Coerce integers so equivalent numeric inputs have one canonical representation.
  defp bounded_number(nil, _minimum, _maximum, _label), do: {:ok, nil}

  defp bounded_number(value, minimum, maximum, _label)
       when is_number(value) and value >= minimum and value <= maximum,
       do: {:ok, value / 1}

  defp bounded_number(_value, minimum, maximum, label),
    do: {:error, "#{label} must be between #{minimum} and #{maximum}"}

  defp positive_integer(value, label, opts \\ [])

  defp positive_integer(nil, label, opts) do
    if Keyword.get(opts, :required?, false) do
      {:error, "#{label} must be a positive integer"}
    else
      {:ok, nil}
    end
  end

  defp positive_integer(value, _label, _opts) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp positive_integer(_value, label, _opts),
    do: {:error, "#{label} must be a positive integer"}

  defp boolean(value, _key) when is_boolean(value), do: {:ok, value}
  defp boolean(_value, key), do: {:error, "requirement #{key} enabled must be boolean"}

  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value), do: to_string(value)

  # Generate prompts from card metadata only, never stored knowledge.
  defp default_prompt(nil, nil, key),
    do: "Please provide current information for #{String.replace(key, ~r/[-_]/, " ")}."

  defp default_prompt(nil, description, _key), do: "Please provide: #{description}"
  defp default_prompt(prompt, _description, _key), do: prompt

  # Drop nil clauses for one canonical map.
  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end

defmodule MemHouse.Skills.Validations.Requirements do
  @moduledoc """
  Rejects skill cards with an incompatible selector version or non-canonical requirements.

  Validation refuses rather than repairs. This lets readiness evaluate storage verbatim and keeps
  equivalent inputs from producing different stored forms.
  """

  use Ash.Resource.Validation

  alias MemHouse.Skills.Selector

  @impl true
  def validate(changeset, _opts, _context) do
    requirements = Ash.Changeset.get_attribute(changeset, :requirements)
    schema_version = Ash.Changeset.get_attribute(changeset, :requirement_schema_version)

    if schema_version != Selector.schema_version() do
      {:error,
       field: :requirement_schema_version, message: "must be #{Selector.schema_version()}"}
    else
      case Selector.validate_requirements(requirements) do
        {:ok, ^requirements} -> :ok
        {:ok, _normalized} -> {:error, field: :requirements, message: "must be normalized"}
        {:error, message} -> {:error, field: :requirements, message: message}
      end
    end
  end
end
