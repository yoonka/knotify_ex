defmodule KnotifyEx do
  @moduledoc """
  A file system watcher powered by Rust's notify crate via the knotify binary.

  ## Usage

  Start a watcher and subscribe to file system events:

      {:ok, pid} = KnotifyEx.start_link(dirs: ["/path/to/watch"])
      KnotifyEx.subscribe(pid)

  Or with a name:

      {:ok, pid} = KnotifyEx.start_link(dirs: ["/path/to/watch"], name: :my_watcher)
      KnotifyEx.subscribe(:my_watcher)

  ## Event Filtering

  Subscribe to specific event types:

      KnotifyEx.subscribe(pid, events: [:create, :modify])

  Available events: `:create`, `:create_folder`, `:modify`, `:remove`, `:remove_folder`, `:rename`

  ## Messages

  Subscribers receive messages in the format:

      {:file_event, watcher_pid, {file_path, events}}
      {:file_event, watcher_pid, :stop}

  ## Example

      defmodule MyWatcher do
        use GenServer

        def start_link(args) do
          GenServer.start_link(__MODULE__, args)
        end

        def init(args) do
          {:ok, watcher_pid} = KnotifyEx.start_link(args)
          KnotifyEx.subscribe(watcher_pid, events: [:create, :modify])
          {:ok, %{watcher_pid: watcher_pid}}
        end

        def handle_info({:file_event, watcher_pid, {path, events}}, state) do
          IO.puts("File changed: \#{path}, events: \#{inspect(events)}")
          {:noreply, state}
        end

        def handle_info({:file_event, watcher_pid, :stop}, state) do
          IO.puts("Watcher stopped")
          {:noreply, state}
        end
      end
  """

  @type event :: :create | :create_folder | :modify | :remove | :remove_folder | :rename
  @type file_path :: String.t()
  @type watcher :: pid() | atom()

  @doc """
  Starts a file system watcher.

  ## Options

    * `:dirs` - List of directories to watch (required)
    * `:name` - Optional name to register the watcher
    * `:recursive` - Watch subdirectories recursively (default: true)
    * `:backend` - Backend to use: `:auto`, `:inotify`, `:kqueue` (default: :auto)
    * `:debounce` - Debounce delay in milliseconds (default: 100)

  ## Examples

      {:ok, pid} = KnotifyEx.start_link(dirs: ["/tmp"])
      {:ok, pid} = KnotifyEx.start_link(dirs: ["/tmp"], name: :temp_watcher)
      {:ok, pid} = KnotifyEx.start_link(dirs: ["/tmp"], recursive: false)
      {:ok, pid} = KnotifyEx.start_link(dirs: ["/tmp"], backend: :inotify)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      KnotifyEx.Worker.start_link(opts, name: name)
    else
      KnotifyEx.Worker.start_link(opts)
    end
  end

  @doc """
  Subscribes the calling process to file system events.

  ## Options

    * `:events` - List of event types to filter (optional)
      Available: `:create`, `:create_folder`, `:modify`, `:remove`, `:remove_folder`, `:rename`
      If not provided, all events are sent.

  ## Examples

      KnotifyEx.subscribe(pid)
      KnotifyEx.subscribe(:my_watcher, events: [:create, :modify])
      KnotifyEx.subscribe(:my_watcher, events: [:create_folder, :remove_folder])
  """
  @spec subscribe(watcher(), keyword()) :: :ok
  def subscribe(watcher, opts \\ []) do
    GenServer.call(watcher, {:subscribe, self(), opts})
  end

  @doc """
  Unsubscribes the calling process from file system events.

  ## Examples

      KnotifyEx.unsubscribe(pid)
      KnotifyEx.unsubscribe(:my_watcher)
  """
  @spec unsubscribe(watcher()) :: :ok
  def unsubscribe(watcher) do
    GenServer.call(watcher, {:unsubscribe, self()})
  end

  @doc """
  Returns the list of directories being watched.

  ## Examples

      KnotifyEx.known_dirs(pid)
      #=> ["/tmp", "/var/log"]
  """
  @spec known_dirs(watcher()) :: [file_path()]
  def known_dirs(watcher) do
    GenServer.call(watcher, :known_dirs)
  end

  @doc """
  Stops the file system watcher.

  ## Examples

      KnotifyEx.stop(pid)
  """
  @spec stop(watcher()) :: :ok
  def stop(watcher) do
    GenServer.stop(watcher)
  end
end
