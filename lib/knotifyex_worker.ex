defmodule KnotifyEx.Worker do
  @moduledoc """
  Internal worker process that manages the knotify binary and handles file system events.

  This module is not part of the public API. You should use the `KnotifyEx` module instead.

  The worker:
    - Spawns and manages the knotify binary as a port
    - Parses JSON events from knotify
    - Manages subscriber processes and event filtering
    - Handles automatic cleanup when subscribers die
  """
  use GenServer
  require Logger

  defstruct [
    :port,
    :dirs,
    :recursive,
    :backend,
    :debounce,
    subscribers: %{}
  ]

  @valid_events [:create, :create_folder, :modify, :remove, :remove_folder, :rename]

  # Mapping from knotify event kinds to our events
  @event_mapping %{
    "CREATE_FILE" => :create,
    "CREATE_FOLDER" => :create_folder,
    "CREATE" => :create,
    "MODIFY_CONTENT" => :modify,
    "MODIFY_SIZE" => :modify,
    "MODIFY_DATA" => :modify,
    "MODIFY" => :modify,
    "RENAME_FROM" => :rename,
    "RENAME_TO" => :rename,
    "RENAME_BOTH" => :rename,
    "RENAME" => :rename,
    "REMOVE_FILE" => :remove,
    "REMOVE_FOLDER" => :remove_folder,
    "REMOVE" => :remove
  }

  ## Public API

  def start_link(opts, genserver_opts \\ []) do
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    dirs = Keyword.fetch!(opts, :dirs)
    recursive = Keyword.get(opts, :recursive, true)
    backend = Keyword.get(opts, :backend, :auto)
    debounce = Keyword.get(opts, :debounce, 100)

    # Validate directories exist
    case validate_dirs(dirs) do
      :ok ->
        state = %__MODULE__{
          dirs: dirs,
          recursive: recursive,
          backend: backend,
          debounce: debounce,
          subscribers: %{}
        }

        {:ok, state, {:continue, :start_watcher}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start_watcher, state) do
    case start_port(state) do
      {:ok, port} ->
        {:noreply, %{state | port: port}}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_call({:subscribe, pid, opts}, _from, state) do
    event_filter = get_event_filter(opts)

    # Monitor the subscriber so we can clean up if it dies
    ref = Process.monitor(pid)

    subscribers =
      Map.put(state.subscribers, pid, %{
        ref: ref,
        events: event_filter
      })

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    state = remove_subscriber(state, pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:known_dirs, _from, state) do
    {:reply, state.dirs, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case decode_event(line) do
      {:ok, paths, events} ->
        # knotify can return multiple paths per event (e.g., rename operations)
        # We'll broadcast each path separately for simplicity
        Enum.each(paths, fn path ->
          broadcast_event(state, {path, events})
        end)

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Failed to decode event: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("knotify binary exited with status: #{status}")
    broadcast_event(state, :stop)
    {:stop, {:port_exit, status}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Subscriber process died, clean up
    state = remove_subscriber(state, pid)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      Port.close(state.port)
    end

    broadcast_event(state, :stop)
    :ok
  end

  ## Private Functions

  defp validate_dirs(dirs) when is_list(dirs) do
    invalid_dirs =
      Enum.reject(dirs, fn dir ->
        File.dir?(dir)
      end)

    case invalid_dirs do
      [] ->
        :ok

      dirs ->
        {:error, {:invalid_directories, dirs}}
    end
  end

  defp validate_dirs(_), do: {:error, :dirs_must_be_list}

  defp start_port(state) do
    executable = find_executable()
    args = build_args(state)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, 1024 * 1024},
        args: args
      ])

    {:ok, port}
  rescue
    e ->
      {:error, {:port_error, e}}
  end

  defp find_executable do
    # Find knotify binary in system PATH
    System.find_executable("knotify") ||
      raise "Could not find knotify binary in system PATH. Please ensure knotify is installed."
  end

  defp build_args(state) do
    base_args = [
      "--json",
      "--debounce",
      to_string(state.debounce),
      "--backend",
      to_string(state.backend)
    ]

    recursive_args =
      if state.recursive do
        ["--recursive"]
      else
        []
      end

    dir_args =
      Enum.flat_map(state.dirs, fn dir ->
        ["--path", dir]
      end)

    base_args ++ recursive_args ++ dir_args
  end

  defp decode_event(data) do
    # Expected JSON format from knotify:
    # {"kind": "CREATE_FILE", "paths": ["/path/to/file"]}
    case Jason.decode(data) do
      {:ok, %{"kind" => kind, "paths" => paths}} when is_list(paths) ->
        case Map.get(@event_mapping, kind) do
          nil ->
            Logger.debug("Unknown event kind: #{kind}")
            {:error, {:unknown_event_kind, kind}}

          event ->
            {:ok, paths, [event]}
        end

      {:ok, invalid} ->
        Logger.warning("Invalid event format: #{inspect(invalid)}")
        {:error, :invalid_format}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  defp get_event_filter(opts) do
    case Keyword.get(opts, :events) do
      nil ->
        :all

      events when is_list(events) ->
        invalid_events = Enum.reject(events, &(&1 in @valid_events))

        if invalid_events != [] do
          raise ArgumentError,
                "Invalid events: #{inspect(invalid_events)}. " <>
                  "Valid events are: #{inspect(@valid_events)}"
        end

        MapSet.new(events)
    end
  end

  defp broadcast_event(state, event) do
    Enum.each(state.subscribers, fn {pid, subscriber_info} ->
      if should_send_event?(event, subscriber_info.events) do
        send(pid, {:file_event, self(), event})
      end
    end)
  end

  defp should_send_event?(:stop, _filter), do: true
  defp should_send_event?(_event, :all), do: true

  defp should_send_event?({_path, events}, filter) when is_map(filter) do
    Enum.any?(events, fn event ->
      MapSet.member?(filter, event)
    end)
  end

  defp remove_subscriber(state, pid) do
    case Map.get(state.subscribers, pid) do
      nil ->
        state

      %{ref: ref} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: Map.delete(state.subscribers, pid)}
    end
  end
end
