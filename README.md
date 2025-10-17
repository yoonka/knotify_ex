# KnotifyEx

File system watcher for Elixir powered by Rust's notify crate.

## Installation

Add `knotify_ex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:knotify_ex, "~> 0.1.0"}
  ]
end
```

## Usage

Start a watcher and subscribe to file system events:

```elixir
{:ok, pid} = KnotifyEx.start_link(dirs: ["/path/to/watch"])
KnotifyEx.subscribe(pid)
```

Subscribe to specific event types:

```elixir
KnotifyEx.subscribe(pid, events: [:create, :modify])
```

Available events: `:create`, `:create_folder`, `:modify`, `:remove`, `:remove_folder`, `:rename`

## Example with GenServer

```elixir
defmodule MyApp.FileWatcher do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    dirs = Keyword.fetch!(opts, :dirs)
    {:ok, watcher} = KnotifyEx.start_link(dirs: dirs)
    KnotifyEx.subscribe(watcher, events: [:create, :modify])
    {:ok, %{watcher: watcher}}
  end

  def handle_info({:file_event, _watcher, {path, events}}, state) do
    IO.puts("File changed: #{path}")
    IO.inspect(events, label: "Events")
    {:noreply, state}
  end

  def handle_info({:file_event, _watcher, :stop}, state) do
    IO.puts("Watcher stopped")
    {:noreply, state}
  end
end
```

Start the watcher in your supervision tree:

```elixir
children = [
  {MyApp.FileWatcher, dirs: ["./lib", "./config"]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Options

- `:dirs` - Directories to watch (required)
- `:name` - Optional name to register the watcher
- `:recursive` - Watch subdirectories (default: true)
- `:backend` - Backend: `:auto`, `:inotify`, `:kqueue` (default: `:auto`)
- `:debounce` - Debounce delay in milliseconds (default: 100)

