module c3io::fswatch_test;

import c3io;
import c3io::event_loop;
import c3io::fswatch;
import c3io::uv;
import c3io::test_support;
import std::thread;
import std::time;
import std::io::path;
import std::io::file;

<*
 Pump the loop without blocking until `#done` or about two seconds pass, so
 a missing event fails the test instead of hanging it.
*>
macro void @pump_for_event(EventLoop* loop, #done)
{
    Clock start = clock::now();
    while (!#done && start.mark().to_ms() < 2000)
    {
        loop.run_nowait();
        thread::sleep_ms(5);
    }
}

struct Changes
{
    int count;
    int status;
    bool saw_target;
    bool any_changed;
}

fn void on_change(FileWatcher* watcher, int status, String filename, WatchEvents events, void* user_data)
{
    Changes* changes = user_data;
    changes.count++;
    changes.status = status;
    if (filename == "watched.txt") changes.saw_target = true;
    if (events.changed || events.renamed) changes.any_changed = true;
}

fn void test_watcher_reports_file_written_in_directory() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    String dir = test_support::temp_path("watch_dir").copy(mem);
    defer free(dir);
    (void)path::rmtree(path::tnew(dir)!!);
    path::mkdir(dir)!!;
    defer (void)path::rmtree(path::tnew(dir)!!);

    FileWatcher* watcher = fswatch::create(&loop)!!;
    Changes changes;
    watcher.start(dir, &on_change, &changes)!!;

    file::save(string::tformat("%s/watched.txt", dir), "new contents")!!;
    @pump_for_event(&loop, changes.saw_target);

    assert(changes.saw_target, "Should report a change to watched.txt");
    assert(changes.status == 0);
    assert(changes.any_changed);

    watcher.close();
    while (loop.is_alive()) loop.run_once();
}

fn void test_watch_missing_path_fails() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    FileWatcher* watcher = fswatch::create(&loop)!!;
    if (try watcher.start(test_support::temp_path("no_such_dir"), &on_change))
    {
        assert(false, "Watching a missing path should fail");
    }
    assert(c3io::error_name(c3io::last_status()) == "ENOENT");
    watcher.close();
    while (loop.is_alive()) loop.run_once();
}

struct Polls
{
    int count;
    int status;
    ulong prev_size;
    ulong curr_size;
}

fn void on_poll(FilePoller* poller, int status, uv::FileStat* prev, uv::FileStat* curr, void* user_data)
{
    Polls* polls = user_data;
    polls.count++;
    polls.status = status;
    if (status == 0)
    {
        polls.prev_size = prev.st_size;
        polls.curr_size = curr.st_size;
    }
}

fn void test_poller_reports_size_change() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    String target = test_support::temp_path("polled.txt").copy(mem);
    defer free(target);
    file::save(target, "1234")!!;
    defer (void)file::delete(target);

    FilePoller* poller = fswatch::create_poller(&loop)!!;
    Polls polls;
    poller.start(target, 20, &on_poll, &polls)!!;

    // Give the poller its first stat, then change the file.
    for (int i = 0; i < 10; i++)
    {
        loop.run_nowait();
        thread::sleep_ms(5);
    }
    file::save(target, "123456789")!!;
    @pump_for_event(&loop, polls.count > 0);

    assert(polls.count > 0, "Should report the change");
    assert(polls.status == 0);
    assert(polls.prev_size == 4 && polls.curr_size == 9);

    poller.close();
    while (loop.is_alive()) loop.run_once();
}

fn void test_unclosed_watchers_are_freed_by_shutdown() @test
{
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    EventLoop loop = event_loop::create(&tracker)!!;
    FileWatcher* watcher = fswatch::create(&loop)!!;
    watcher.start(".", &on_change)!!;
    FilePoller* poller = fswatch::create_poller(&loop)!!;
    poller.start(".", 1000, &on_poll)!!;

    assert(loop.shutdown());
    loop.free()!!;
    assert(tracker.allocation_count() == 0);
}
