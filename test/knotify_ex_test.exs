defmodule KnotifyExTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @test_dir "/tmp/knotify_test_#{System.unique_integer([:positive])}"
  @test_file Path.join(@test_dir, "test_file.txt")

  setup do
    # Create test directory
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      # Cleanup test directory
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts a watcher with valid directory" do
      assert {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir])
      assert Process.alive?(pid)
      KnotifyEx.stop(pid)
    end

    test "starts a named watcher" do
      assert {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir], name: :test_watcher)
      assert Process.whereis(:test_watcher) == pid
      KnotifyEx.stop(pid)
    end

    test "returns error for non-existent directory" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_directories, ["/nonexistent/path"]}} =
               KnotifyEx.start_link(dirs: ["/nonexistent/path"])
    end

    test "returns error when dirs is not a list" do
      Process.flag(:trap_exit, true)

      assert {:error, :dirs_must_be_list} = KnotifyEx.start_link(dirs: "not_a_list")
    end

    test "accepts recursive option" do
      assert {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir], recursive: false)
      assert Process.alive?(pid)
      KnotifyEx.stop(pid)
    end

    test "accepts backend option" do
      assert {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir], backend: :kqueue)
      assert Process.alive?(pid)
      KnotifyEx.stop(pid)
    end

    test "accepts debounce option" do
      assert {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir], debounce: 200)
      assert Process.alive?(pid)
      KnotifyEx.stop(pid)
    end
  end

  describe "subscribe/2" do
    setup do
      {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir])
      %{watcher: pid}
    end

    test "subscribes to all events by default", %{watcher: watcher} do
      assert :ok = KnotifyEx.subscribe(watcher)
      KnotifyEx.stop(watcher)
    end

    test "subscribes to specific events", %{watcher: watcher} do
      assert :ok = KnotifyEx.subscribe(watcher, events: [:create, :modify])
      KnotifyEx.stop(watcher)
    end

    test "raises error for invalid event types", %{watcher: watcher} do
      assert_raise ArgumentError, ~r/Invalid events/, fn ->
        KnotifyEx.subscribe(watcher, events: [:invalid_event])
      end

      KnotifyEx.stop(watcher)
    end

    test "accepts folder event types", %{watcher: watcher} do
      assert :ok = KnotifyEx.subscribe(watcher, events: [:create_folder, :remove_folder])
      KnotifyEx.stop(watcher)
    end

    test "allows multiple subscribers", %{watcher: watcher} do
      task1 = Task.async(fn -> KnotifyEx.subscribe(watcher) end)
      task2 = Task.async(fn -> KnotifyEx.subscribe(watcher) end)

      assert :ok = Task.await(task1)
      assert :ok = Task.await(task2)

      KnotifyEx.stop(watcher)
    end
  end

  describe "unsubscribe/1" do
    setup do
      {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir])
      %{watcher: pid}
    end

    test "unsubscribes from events", %{watcher: watcher} do
      KnotifyEx.subscribe(watcher)
      assert :ok = KnotifyEx.unsubscribe(watcher)
      KnotifyEx.stop(watcher)
    end

    test "unsubscribing without subscribing is safe", %{watcher: watcher} do
      assert :ok = KnotifyEx.unsubscribe(watcher)
      KnotifyEx.stop(watcher)
    end
  end

  describe "known_dirs/1" do
    test "returns the list of watched directories" do
      test_dir2 = "/tmp/knotify_test_known_#{System.unique_integer([:positive])}"
      File.mkdir_p!(test_dir2)

      on_exit(fn ->
        File.rm_rf!(test_dir2)
      end)

      dirs = [@test_dir, test_dir2]
      {:ok, pid} = KnotifyEx.start_link(dirs: dirs)
      assert KnotifyEx.known_dirs(pid) == dirs
      KnotifyEx.stop(pid)
    end
  end

  describe "stop/1" do
    test "stops the watcher" do
      {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir])
      assert :ok = KnotifyEx.stop(pid)
      refute Process.alive?(pid)
    end

    test "broadcasts stop message to subscribers" do
      {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir])
      KnotifyEx.subscribe(pid)
      KnotifyEx.stop(pid)

      assert_receive {:file_event, ^pid, :stop}, 1000
    end
  end

  describe "file system events" do
    setup do
      {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir], debounce: 50)
      KnotifyEx.subscribe(pid)

      # Give the watcher time to fully initialize
      Process.sleep(100)

      %{watcher: pid}
    end

    @tag :integration
    test "receives create event when file is created", %{watcher: watcher} do
      File.write!(@test_file, "content")

      assert_receive {:file_event, ^watcher, {path, events}}, 10000
      assert path == @test_file
      assert :create in events
    end

    @tag :integration
    test "receives modify event when file is modified", %{watcher: watcher} do
      File.write!(@test_file, "content")
      # Wait for create event
      assert_receive {:file_event, ^watcher, _}, 10000

      # Modify the file
      File.write!(@test_file, "new content")

      assert_receive {:file_event, ^watcher, {path, events}}, 10000
      assert path == @test_file
      assert :modify in events
    end

    @tag :integration
    test "receives remove event when file is deleted", %{watcher: watcher} do
      File.write!(@test_file, "content")
      # Wait for create event
      assert_receive {:file_event, ^watcher, _}, 10000

      # Delete the file
      File.rm!(@test_file)

      assert_receive {:file_event, ^watcher, {path, events}}, 10000
      assert path == @test_file
      assert :remove in events
    end

    @tag :integration
    test "receives create_folder event when directory is created", %{watcher: watcher} do
      new_dir = Path.join(@test_dir, "new_folder")
      File.mkdir!(new_dir)

      assert_receive {:file_event, ^watcher, {path, events}}, 10000
      assert path == new_dir
      assert :create_folder in events
    end

    @tag :integration
    test "receives remove_folder event when directory is deleted", %{watcher: watcher} do
      new_dir = Path.join(@test_dir, "folder_to_delete")
      File.mkdir!(new_dir)
      # Wait for create event
      assert_receive {:file_event, ^watcher, _}, 10000

      # Delete the folder
      File.rmdir!(new_dir)

      assert_receive {:file_event, ^watcher, {path, events}}, 10000
      assert path == new_dir
      assert :remove_folder in events
    end

    @tag :integration
    test "filters events based on subscription", %{watcher: watcher} do
      # Unsubscribe and resubscribe with filter
      KnotifyEx.unsubscribe(watcher)
      KnotifyEx.subscribe(watcher, events: [:modify])

      # Create a file (should not receive this event)
      File.write!(@test_file, "content")
      refute_receive {:file_event, ^watcher, {_, [:create]}}, 1000

      # Modify the file (should receive this event)
      File.write!(@test_file, "modified")
      assert_receive {:file_event, ^watcher, {path, events}}, 10000
      assert path == @test_file
      assert :modify in events
    end

    @tag :integration
    test "filters folder events based on subscription", %{watcher: watcher} do
      # Unsubscribe and resubscribe with folder filter
      KnotifyEx.unsubscribe(watcher)
      KnotifyEx.subscribe(watcher, events: [:create_folder, :remove_folder])

      # Create a file (should not receive this event)
      File.write!(@test_file, "content")
      refute_receive {:file_event, ^watcher, {^file, _}}, 1000

      # Create a folder (should receive this event)
      new_dir = Path.join(@test_dir, "filtered_folder")
      File.mkdir!(new_dir)
      assert_receive {:file_event, ^watcher, {path, events}}, 10000
      assert path == new_dir
      assert :create_folder in events
    end
  end

  describe "subscriber cleanup" do
    setup do
      {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir])
      %{watcher: pid}
    end

    test "removes subscriber when process dies", %{watcher: watcher} do
      # Start a process that subscribes
      {:ok, subscriber} =
        Task.start(fn ->
          KnotifyEx.subscribe(watcher)
          receive do: (:wait -> :ok)
        end)

      # Give it time to subscribe
      Process.sleep(50)

      # Kill the subscriber
      Process.exit(subscriber, :kill)
      Process.sleep(50)

      # Watcher should still be alive
      assert Process.alive?(watcher)
      KnotifyEx.stop(watcher)
    end
  end

  describe "multiple directories" do
    setup do
      test_dir2 = "/tmp/knotify_test2_#{System.unique_integer([:positive])}"
      File.mkdir_p!(test_dir2)

      on_exit(fn ->
        File.rm_rf!(test_dir2)
      end)

      {:ok, pid} = KnotifyEx.start_link(dirs: [@test_dir, test_dir2], debounce: 50)
      KnotifyEx.subscribe(pid)

      # Give the watcher time to fully initialize
      Process.sleep(100)

      %{watcher: pid, test_dir2: test_dir2}
    end

    @tag :integration
    test "watches multiple directories", %{watcher: watcher, test_dir2: test_dir2} do
      file1 = Path.join(@test_dir, "file1.txt")
      file2 = Path.join(test_dir2, "file2.txt")

      File.write!(file1, "content1")
      assert_receive {:file_event, ^watcher, {^file1, _}}, 10000

      File.write!(file2, "content2")
      assert_receive {:file_event, ^watcher, {^file2, _}}, 10000
    end
  end
end
