# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Update do
  @moduledoc """
  Checks, verifies, stages, and activates standalone release updates.

  Release metadata is discovery-only until its detached Ed25519 signature verifies. The updater
  is intentionally unavailable for containers and external PostgreSQL: replacing an image or
  coordinating an operator-managed database belongs to that deployment's orchestrator.
  """

  require Logger

  @manifest_schema "memhouse-release-1"
  @default_source "https://api.github.com/repos/memhousehq/memhouse/releases/latest"
  @timeout 10_000

  @doc "Returns the content-safe update status used by readiness and the operations console."
  def status do
    Application.get_env(:memhouse, :update, [])
    |> Keyword.merge(last_result: persistent_result())
    |> Map.new()
    |> Map.merge(%{
      status: "not_checked",
      current_version: current_version(),
      available_version: nil,
      automatic_eligible: false,
      command: nil
    })
    |> Map.merge(persistent_result())
  end

  @doc "Checks the configured official release feed and persists a content-safe result."
  def check do
    result = do_check(Application.get_env(:memhouse, :update, []))
    :persistent_term.put({__MODULE__, :result}, result)
    result
  end

  @doc "Checks an explicit configuration. Public for deterministic updater tests."
  def do_check(config) when is_list(config) do
    with :ok <- checking_enabled?(config),
         {:ok, latest} <- latest_release(config),
         {:ok, manifest, signature} <- fetch_manifest(latest, config),
         {:ok, decoded} <- verify_manifest(manifest, signature, config),
         :ok <- validate_manifest(decoded, latest) do
      current = current_version()
      available = decoded["version"]

      %{
        status: "ok",
        checked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        current_version: current,
        available_version: available,
        update_available: newer?(available, current),
        automatic_eligible: automatic_eligible?(decoded, current, config),
        command: "bin/update --version #{available}"
      }
    else
      {:error, reason} -> failure(reason)
    end
  end

  @doc "Verifies the signed manifest bytes with the configured Ed25519 public key."
  def verify_manifest(manifest, signature, config)
      when is_binary(manifest) and is_binary(signature) do
    with {:ok, public_key} <- decode_key(Keyword.get(config, :public_key)),
         {:ok, decoded} <- Jason.decode(manifest),
         {:ok, signature} <- Base.decode64(signature),
         true <- :crypto.verify(:eddsa, :none, manifest, signature, [public_key, :ed25519]) do
      {:ok, decoded}
    else
      false -> {:error, :invalid_signature}
      :error -> {:error, :invalid_signature}
      {:error, _reason} = error -> error
    end
  end

  @doc "Stages, checkpoints, migrates, and atomically activates an already-verified release."
  # The install root is operator configuration; archive paths are admitted only after signed
  # manifest and checksum verification below.
  # sobelow_skip ["Traversal.FileModule"]
  def activate!(manifest, archive_path, config) do
    :ok = supported_install?(config)
    :ok = validate_manifest(manifest, %{tag_name: "v#{manifest["version"]}"})

    version = manifest["version"]
    install_root = Keyword.fetch!(config, :install_root)
    releases_root = Path.join(install_root, "releases")
    staged = Path.join(releases_root, version)
    temporary = staged <> ".staging-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.mkdir_p!(releases_root)
      ensure_new_release!(staged)
      verify_asset!(archive_path, manifest, config)
      extract_release!(archive_path, temporary)
      release_root = Path.join(temporary, "memhouse")
      ensure_release_root!(release_root)
      checkpoint!()
      run_migrations!(release_root)
      File.rename!(temporary, staged)
      switch_current!(install_root, staged)

      Logger.info("MemHouse update activated version=#{version}")
      %{version: version, release_root: staged}
    after
      if File.exists?(temporary), do: File.rm_rf!(temporary)
    end
  end

  @doc "Downloads and activates one explicitly requested newer stable release."
  # `archive` is a generated temporary path, never a user-supplied filename.
  # sobelow_skip ["Traversal.FileModule"]
  def apply!(version) when is_binary(version) do
    config = resolved_config()
    :ok = supported_install?(config)

    with {:ok, _} <- parse_version(version),
         true <- newer?(version, current_version()),
         {:ok, manifest_bytes, signature} <- fetch_manifest_for(version),
         {:ok, manifest} <- verify_manifest(manifest_bytes, signature, config),
         :ok <- validate_manifest(manifest, %{tag_name: "v#{version}"}),
         {:ok, asset} <- platform_asset(manifest, config) do
      archive = download_asset!(version, asset)

      try do
        activate!(manifest, archive, config)
      after
        File.rm(archive)
      end
    else
      false -> raise "requested update is not newer than #{current_version()}"
      {:error, reason} -> raise "cannot apply update: #{inspect(reason)}"
    end
  end

  @doc "Creates and validates the existing logical archive before a schema upgrade."
  # The backup directory is derived from trusted local deployment configuration.
  # sobelow_skip ["Traversal.FileModule"]
  def checkpoint! do
    data_root = System.get_env("MEMHOUSE_DATA_ROOT") || Path.expand("~/.memhouse")
    backups = Path.join(data_root, "backups")
    File.mkdir_p!(backups)
    File.chmod!(backups, 0o700)
    archive = Path.join(backups, "before-update-#{System.system_time(:second)}.tar.gz")

    {:ok, _started} = Application.ensure_all_started(:memhouse)

    try do
      MemHouse.Release.export!(archive)
      MemHouse.Release.validate_archive!(archive)
      archive
    after
      Application.stop(:memhouse)
    end
  end

  @doc "Compares SemVer versions without accepting prereleases as automatic targets."
  def newer?(candidate, current) when is_binary(candidate) and is_binary(current) do
    case {parse_version(candidate), parse_version(current)} do
      {{:ok, candidate}, {:ok, current}} -> candidate > current
      _ -> false
    end
  end

  defp latest_release(config) do
    source = Keyword.get(config, :source, @default_source)

    with {:ok, %{status: 200, body: body}} <- request(source),
         %{"tag_name" => tag} <- body,
         {:ok, version} <- semver_tag(tag) do
      {:ok, %{tag_name: tag, version: version, manifest_url: manifest_url(source, tag)}}
    else
      _ -> {:error, :release_feed_unavailable}
    end
  end

  defp fetch_manifest(latest, _config) do
    with {:ok, %{status: 200, body: manifest}} <- raw_request(latest.manifest_url),
         {:ok, %{status: 200, body: signature}} <- raw_request(latest.manifest_url <> ".sig") do
      {:ok, manifest, signature}
    else
      _ -> {:error, :signed_manifest_unavailable}
    end
  end

  defp fetch_manifest_for(version) do
    url = manifest_url(@default_source, "v#{version}")

    with {:ok, %{status: 200, body: manifest}} <- raw_request(url),
         {:ok, %{status: 200, body: signature}} <- raw_request(url <> ".sig") do
      {:ok, manifest, signature}
    else
      _ -> {:error, :signed_manifest_unavailable}
    end
  end

  defp request(url) do
    Req.get(url,
      receive_timeout: @timeout,
      retry: false,
      headers: [{"accept", "application/json"}]
    )
  end

  defp raw_request(url),
    do: Req.get(url, receive_timeout: @timeout, retry: false, decode_body: false)

  defp manifest_url(_source, tag),
    do: "https://github.com/memhousehq/memhouse/releases/download/#{tag}/release-manifest-v1.json"

  defp validate_manifest(%{"schema" => @manifest_schema, "version" => version}, latest) do
    with {:ok, ^version} <- semver_tag(latest.tag_name),
         {:ok, _parsed} <- parse_version(version) do
      :ok
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  defp validate_manifest(_, _), do: {:error, :invalid_manifest}

  defp automatic_eligible?(manifest, current, config) do
    Keyword.get(config, :database_mode) == "pg0" and
      Keyword.get(config, :auto_update, :off) == :minor and
      manifest["automatic_eligible"] == true and
      same_major?(manifest["version"], current) and newer?(manifest["version"], current)
  end

  defp same_major?(left, right) do
    with {:ok, {left_major, _, _}} <- parse_version(left),
         {:ok, {right_major, _, _}} <- parse_version(right) do
      left_major == right_major
    else
      _ -> false
    end
  end

  defp supported_install?(config) do
    if Keyword.get(config, :enabled, true) and
         Keyword.get(config, :database_mode, "external") == "pg0" do
      :ok
    else
      {:error, :managed_deployment}
    end
  end

  defp checking_enabled?(config) do
    if Keyword.get(config, :enabled, true), do: :ok, else: {:error, :update_checks_disabled}
  end

  defp decode_key(key) when is_binary(key), do: Base.decode64(key, padding: false) |> key_result()
  defp decode_key(_), do: {:error, :missing_public_key}
  defp key_result({:ok, <<_::binary-size(32)>> = key}), do: {:ok, key}
  defp key_result(_), do: {:error, :invalid_public_key}

  defp current_version do
    :memhouse |> Application.spec(:vsn) |> to_string()
  end

  defp parse_version(value) do
    case Regex.run(~r/^([0-9]+)\.([0-9]+)\.([0-9]+)$/, value, capture: :all_but_first) do
      [major, minor, patch] ->
        {:ok, {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}}

      _ ->
        {:error, :invalid_version}
    end
  end

  defp semver_tag("v" <> version),
    do:
      parse_version(version)
      |> then(fn
        {:ok, _} -> {:ok, version}
        error -> error
      end)

  defp semver_tag(_), do: {:error, :invalid_tag}

  defp failure(reason),
    do: %{
      status: "error",
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      error: Atom.to_string(reason)
    }

  defp persistent_result,
    do: :persistent_term.get({__MODULE__, :result}, %{status: "not_checked"})

  defp resolved_config do
    config = Application.get_env(:memhouse, :update, [])
    release_root = System.get_env("RELEASE_ROOT") || File.cwd!()
    install_root = Keyword.get(config, :install_root) || Path.dirname(release_root)
    Keyword.put(config, :install_root, install_root)
  end

  defp ensure_new_release!(path),
    do: if(File.exists?(path), do: raise("release already installed: #{path}"), else: :ok)

  # `archive` is created by `download_asset!/2` after a signed manifest selects its digest.
  # sobelow_skip ["Traversal.FileModule"]
  defp verify_asset!(archive, manifest, config) do
    {:ok, asset} = platform_asset(manifest, config)
    expected = asset["sha256"]
    actual = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)

    if is_binary(expected) and expected == actual,
      do: :ok,
      else: raise("update archive checksum mismatch")
  end

  defp platform_asset(manifest, config) do
    case Enum.find(
           manifest["assets"] || [],
           &(&1["platform"] == Keyword.fetch!(config, :platform))
         ) do
      %{"name" => name, "sha256" => sha256} = asset when is_binary(name) and is_binary(sha256) ->
        {:ok, asset}

      _ ->
        {:error, :unsupported_platform}
    end
  end

  # The destination filename is generated; only verified release bytes are written to it.
  # sobelow_skip ["Traversal.FileModule"]
  defp download_asset!(version, asset) do
    url =
      "https://github.com/memhousehq/memhouse/releases/download/v#{version}/#{asset["name"]}"

    case raw_request(url) do
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) ->
        path =
          Path.join(System.tmp_dir!(), "memhouse-update-#{System.unique_integer([:positive])}")

        File.write!(path, bytes, [:binary])
        path

      _ ->
        raise "cannot download update archive"
    end
  end

  # `temporary` is generated beside the operator-owned install root.
  # sobelow_skip ["Traversal.FileModule"]
  defp extract_release!(archive, temporary) do
    File.mkdir_p!(temporary)

    extraction =
      if String.ends_with?(archive, ".zip") do
        :zip.extract(String.to_charlist(archive), cwd: String.to_charlist(temporary))
      else
        :erl_tar.extract(String.to_charlist(archive), [
          :compressed,
          cwd: String.to_charlist(temporary)
        ])
      end

    case extraction do
      :ok -> :ok
      {:ok, _files} -> :ok
      {:error, reason} -> raise "cannot extract update archive: #{inspect(reason)}"
    end
  end

  defp ensure_release_root!(root) do
    migration = if match?({:win32, _}, :os.type()), do: "bin/migrate.bat", else: "bin/migrate"

    if File.regular?(Path.join(root, migration)),
      do: :ok,
      else: raise("update archive has no release root")
  end

  # The command is the fixed migration launcher inside the signed, staged release.
  # sobelow_skip ["CI.System"]
  defp run_migrations!(root) do
    {command, args} =
      if match?({:win32, _}, :os.type()) do
        {"cmd", ["/c", Path.join(root, "bin/migrate.bat")]}
      else
        {Path.join(root, "bin/migrate"), []}
      end

    {_, status} = System.cmd(command, args, stderr_to_stdout: true)
    if status == 0, do: :ok, else: raise("staged release migration failed")
  end

  # Both paths are derived from the configured install root and validated staged version.
  # sobelow_skip ["Traversal.FileModule"]
  defp switch_current!(install_root, staged) do
    temporary = Path.join(install_root, ".current-#{System.unique_integer([:positive])}")
    File.ln_s!(staged, temporary)
    File.rename!(temporary, Path.join(install_root, "current"))
  end
end
