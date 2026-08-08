# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pg0 do
  @moduledoc """
  Supervises the embedded PostgreSQL process for no-container installs.

  The binary version and platform checksum are pinned, data stays under the private release root,
  and pg0 becomes ready before Repo and migrations start. External-Postgres mode skips only this
  infrastructure process; application behavior and guarantees stay identical.
  """

  use GenServer

  require Logger

  # 30 s (30_000 ms) budget for a freshly started server to accept TCP
  # connections. A first start initialises a cluster on disk, which is far
  # slower than a restart, so this is generous on purpose.
  @startup_timeout_ms 30_000
  @vectorscale_version "0.9.0"

  @doc """
  Starts the launcher under the supervision tree, registered under the module name.

  Options are accepted and ignored: everything comes from the node's
  configuration. Returns once the database accepts connections. All the work
  happens in `init/1`, so an unusable data directory, a port occupied by a
  foreign process, a helper that fails to start, or a server that does not
  become reachable in time raises there and the start fails.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stops the supervised database and waits for it to shut down.

  Called during an orderly node shutdown, before the supervision tree is torn
  down. Always returns `:ok` — a database that refuses to stop cleanly is
  logged, not raised, because failing here would abort the rest of shutdown.

  The 35 s (35_000 ms) call timeout is deliberately longer than the 30 s the
  helper is given to stop the server, so the caller waits for a real answer
  rather than timing out on a shutdown that is still in progress.
  """
  def stop_database do
    GenServer.call(__MODULE__, :stop_database, 35_000)
  end

  # All the work happens here so that the supervisor blocks until the database
  # is reachable. The configuration is kept as state purely so shutdown knows
  # which named instance to stop.
  @impl true
  def init(_opts) do
    config = pg0_config()
    prepare_data_dir!(config)
    start_or_attach!(config)
    stage_vectorscale!(config)
    {:ok, config}
  end

  # Only reached when this process is stopped deliberately (the release stop
  # path does that). A plain supervisor shutdown skips it, because the process
  # does not trap exits — hence the explicit call during application shutdown.
  @impl true
  def terminate(_reason, config) do
    stop_database(config)
  end

  @impl true
  def handle_call(:stop_database, _from, config) do
    {:reply, stop_database(config), config}
  end

  # Executable path and instance name come from validated configuration, never
  # from request input, which is why shelling out here is safe.
  #
  # `--timeout 30` gives the server 30 s to shut down cleanly. A non-zero exit
  # is logged rather than raised: shutdown must continue even if the database
  # is wedged, and the log line names only the instance, never any content.
  # sobelow_skip ["CI.System"]
  defp stop_database(config) do
    {_output, status} =
      System.cmd(config[:binary], ["stop", "--name", config[:name], "--timeout", "30"],
        stderr_to_stdout: true
      )

    if status != 0 do
      Logger.warning("pg0 instance #{config[:name]} did not stop cleanly")
    end

    :ok
  end

  @doc """
  Supervision child specification.

  Written out rather than taken from the default so the shutdown budget can be
  35 s (35_000 ms): the supervisor must wait longer than the 30 s the database
  is given to stop, or it would kill this process mid-shutdown and leave a
  running server behind.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 35_000,
      type: :worker
    }
  end

  @doc """
  Verifies and stages the packaged pgvectorscale files into pg0's installation.

  The target is keyed by PostgreSQL version. Matching files are unchanged;
  changed files use an atomic rename so boot cannot expose a partial library or
  SQL file. Raises on a missing file, digest mismatch, or unsafe manifest path.
  """
  # Package and installation roots come from validated release configuration;
  # every manifest entry is constrained below both roots before file access.
  # sobelow_skip ["Traversal.FileModule"]
  def stage_vectorscale!(config) do
    source_root = Keyword.fetch!(config, :vectorscale_dir)
    installation_root = Keyword.fetch!(config, :installation_root)
    postgres_version = Keyword.fetch!(config, :postgres_version)
    manifest_path = Path.join(source_root, "manifest.sha256")

    unless File.read!(Path.join(source_root, "VERSION")) == @vectorscale_version <> "\n" do
      raise "packaged pgvectorscale version must be #{@vectorscale_version}"
    end

    manifest_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      {expected, relative} = manifest_entry!(line)
      source = safe_manifest_path!(source_root, relative)
      target = safe_manifest_path!(Path.join(installation_root, postgres_version), relative)
      verify_digest!(source, expected)

      if not File.regular?(target) or digest(target) != expected do
        File.mkdir_p!(Path.dirname(target))

        temporary =
          target <> ".memhouse-stage-" <> Integer.to_string(System.unique_integer([:positive]))

        File.cp!(source, temporary)
        File.rename!(temporary, target)
      end
    end)

    :ok
  end

  # Read at boot rather than held as a module attribute, so the values come from
  # the environment this node actually started in and not from compile time.
  defp pg0_config do
    :memhouse
    |> Application.fetch_env!(:database)
    |> Keyword.fetch!(:pg0)
  end

  defp manifest_entry!(line) do
    case String.split(line, ~r/\s+/, parts: 2, trim: true) do
      [digest, relative] when byte_size(digest) == 64 -> {String.downcase(digest), relative}
      _other -> raise "invalid pgvectorscale manifest entry"
    end
  end

  defp safe_manifest_path!(root, relative) do
    expanded = Path.expand(relative, root)
    root = Path.expand(root)

    if Path.type(relative) != :relative or expanded == root or
         not String.starts_with?(expanded, root <> "/") do
      raise "unsafe pgvectorscale manifest path"
    end

    expanded
  end

  defp verify_digest!(path, expected) do
    unless File.regular?(path) and digest(path) == expected do
      raise "pgvectorscale checksum mismatch for #{Path.basename(path)}"
    end
  end

  # Callers pass paths that were constrained to the configured source or target
  # root. No request data reaches this helper.
  # sobelow_skip ["Traversal.FileModule"]
  defp digest(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Fails fast on an unusable data directory rather than letting the database
  # discover the problem later. The write probe exists because a directory can
  # be creatable and still not writable by this user — a mounted volume with the
  # wrong ownership is the common case, and finding out here produces a clear
  # error instead of a confusing server crash.
  #
  # The root is an absolute path from validated configuration, not request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp prepare_data_dir!(config) do
    data_dir = config[:data_dir]
    parent = Path.dirname(data_dir)
    File.mkdir_p!(parent)

    if File.exists?(data_dir) and not File.dir?(data_dir) do
      raise "pg0 data path exists but is not a directory: #{data_dir}"
    end

    File.mkdir_p!(data_dir)
    writable_probe = Path.join(data_dir, ".memhouse-write-check")
    File.write!(writable_probe, "ok", [:binary])
    File.rm!(writable_probe)
    handle_postmaster_pid!(Path.join(data_dir, "postmaster.pid"))
  end

  # Decides whether an existing pid file means "a server is already running" or
  # "the last one died badly".
  #
  # A live process means attach. A dead one means the file is stale, and it is
  # renamed with a timestamp suffix rather than deleted, so an operator
  # investigating a crash still has it. An unparseable file raises instead of
  # being cleaned up: something unexpected owns this directory, and starting a
  # second server over another server's data is how a cluster gets corrupted.
  #
  # `path` is derived from the validated data root, not from request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp handle_postmaster_pid!(path) do
    case File.read(path) do
      {:ok, contents} ->
        with [pid_line | _rest] <- String.split(contents, "\n"),
             {pid, ""} <- Integer.parse(String.trim(pid_line)) do
          if process_alive?(pid) do
            :ok
          else
            stale = path <> ".stale-" <> Integer.to_string(System.system_time(:second))
            File.rename!(path, stale)
            Logger.warning("moved stale pg0 postmaster pid to #{stale}")
          end
        else
          _other -> raise "invalid pg0 postmaster.pid at #{path}"
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "cannot inspect pg0 postmaster.pid: #{inspect(reason)}"
    end
  end

  # Is that OS process still there? On Unix, signal 0 performs the existence
  # check without delivering anything. Windows has no equivalent, so the process
  # list is filtered by pid instead.
  defp process_alive?(pid) when is_integer(pid) and pid > 0 do
    case :os.type() do
      {:win32, _name} ->
        {output, status} =
          System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH"], stderr_to_stdout: true)

        status == 0 and String.contains?(output, Integer.to_string(pid))

      _unix ->
        case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_output, 0} -> true
          {_output, _status} -> false
        end
    end
  end

  # Either adopts the instance already running in this data directory, or starts
  # a new one. By this point a stale pid file has already been moved aside, so a
  # surviving file means a live server and attaching is the correct, idempotent
  # outcome — restarting the release must not start a second server over the
  # same data.
  #
  # The port check only runs on the start path: on the attach path the port is
  # occupied by our own server, and refusing it would make a restart impossible.
  #
  # Both branches end at the readiness wait, so this returns only once something
  # is actually listening — which is what lets the repository start next.
  #
  # The executable and every argument come from validated configuration, not
  # from request input.
  # sobelow_skip ["CI.System"]
  defp start_or_attach!(config) do
    pid_path = Path.join(config[:data_dir], "postmaster.pid")

    if File.exists?(pid_path) do
      Logger.info("attaching to release-owned pg0 instance #{config[:name]}")
    else
      ensure_port_available!(config[:port])

      args = [
        "start",
        "--name",
        config[:name],
        "--port",
        Integer.to_string(config[:port]),
        "--version",
        config[:postgres_version],
        "--data-dir",
        config[:data_dir],
        "--username",
        config[:username],
        "--password",
        config[:password],
        "--database",
        config[:database]
      ]

      {output, status} = System.cmd(config[:binary], args, stderr_to_stdout: true)

      if status != 0 do
        raise "pg0 failed to start: #{String.trim(output)}"
      end
    end

    wait_for_port!(config[:port], @startup_timeout_ms)
  end

  # Refuses to start when something already listens on the configured port.
  # Silently proceeding would leave the release talking to whatever database
  # happens to be there — a developer's own server, or another install — which
  # is far worse than failing to boot. 250 ms is ample for a loopback connect.
  defp ensure_port_available!(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        raise "pg0 port #{port} is already in use; choose MEMHOUSE_PG0_PORT or use external mode"

      {:error, _reason} ->
        :ok
    end
  end

  # Blocks until the server accepts a TCP connection, or gives up.
  #
  # A successful connect is the readiness signal, so this returns only when the
  # database can actually be reached. `remaining` counts down in units of the
  # 100 ms sleep between attempts and does not include the time a connect
  # attempt itself takes, so the real wall-clock wait can exceed the nominal
  # budget on a host where connects hang. That is intentional slack, not a bug:
  # the deadline exists to fail eventually, not to fail precisely.
  defp wait_for_port!(_port, remaining) when remaining <= 0 do
    raise "pg0 did not become ready before the startup deadline"
  end

  defp wait_for_port!(port, remaining) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        Process.sleep(100)
        wait_for_port!(port, remaining - 100)
    end
  end
end
