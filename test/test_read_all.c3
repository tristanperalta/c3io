module c3io::read_all_test;

import c3io;
import c3io::event_loop;
import c3io::file;
import c3io::work;
import c3io::uv;
import c3io::test_support;
import std::thread;
import std::io::file;

struct Loaded
{
    bool done;
    int status;
    char[] data;
}

fn void on_loaded(char[] data, int status, void* user_data)
{
    Loaded* loaded = user_data;
    loaded.done = true;
    loaded.status = status;
    loaded.data = data;
}

fn void test_read_all_small_file() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;
    String path = test_support::temp_path("read_all_small.txt").copy(mem);
    defer free(path);
    std::io::file::save(path, "hello, asset loader")!!;
    defer (void)std::io::file::delete(path);

    Loaded loaded;
    c3io::file::read_all(&loop, path, &on_loaded, &loaded)!!;
    while (!loaded.done) loop.run_once();

    assert(loaded.status == 0);
    assert((String)loaded.data == "hello, asset loader");
    free(loaded.data);
}

fn void test_read_all_large_file() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;
    String path = test_support::temp_path("read_all_large.bin").copy(mem);
    defer free(path);

    char[] expected = mem::new_array(char, 3 * 1024 * 1024 + 17);
    defer free(expected);
    foreach (i, &c : expected) *c = (char)(i * 31 + 7);
    std::io::file::save(path, expected)!!;
    defer (void)std::io::file::delete(path);

    Loaded loaded;
    c3io::file::read_all(&loop, path, &on_loaded, &loaded)!!;
    while (!loaded.done) loop.run_once();

    assert(loaded.status == 0);
    assert(loaded.data == expected, "Contents should match");
    free(loaded.data);
}

fn void test_read_all_empty_file() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;
    String path = test_support::temp_path("read_all_empty.txt").copy(mem);
    defer free(path);
    std::io::file::save(path, "")!!;
    defer (void)std::io::file::delete(path);

    Loaded loaded;
    c3io::file::read_all(&loop, path, &on_loaded, &loaded)!!;
    while (!loaded.done) loop.run_once();

    assert(loaded.status == 0);
    assert(loaded.data.len == 0);
}

fn void test_read_all_missing_file() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    Loaded loaded;
    c3io::file::read_all(&loop, test_support::temp_path("does_not_exist"), &on_loaded, &loaded)!!;
    while (!loaded.done) loop.run_once();

    assert(loaded.status < 0);
    assert(c3io::error_name(loaded.status) == "ENOENT");
    assert(loaded.data.len == 0 && loaded.data.ptr == null);
}

fn void sleep_100ms(void* arg)
{
    thread::sleep_ms(100);
}

fn void test_read_all_cancelled_before_start() @test
{
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    EventLoop loop = event_loop::create(&tracker)!!;
    String path = test_support::temp_path("read_all_cancel.txt").copy(mem);
    defer free(path);
    std::io::file::save(path, "never read")!!;
    defer (void)std::io::file::delete(path);

    // Occupy the thread pool so the open has to wait.
    for (int i = 0; i < 4; i++) work::queue(&loop, &sleep_100ms)!!;
    thread::sleep_ms(20);

    Loaded loaded;
    event_loop::RequestId id = file::read_all(&loop, path, &on_loaded, &loaded)!!;
    assert(loop.cancel(id));
    while (!loaded.done) loop.run_once();
    assert(loaded.status == uv::UV_ECANCELED);
    assert(loaded.data.len == 0);

    while (!loop.shutdown()) thread::sleep_ms(5);
    loop.free()!!;
    assert(tracker.allocation_count() == 0, "Nothing should leak");
}

fn void test_read_all_uses_given_allocator() @test
{
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;
    String path = test_support::temp_path("read_all_alloc.txt").copy(mem);
    defer free(path);
    std::io::file::save(path, "0123456789")!!;
    defer (void)std::io::file::delete(path);

    Loaded loaded;
    c3io::file::read_all(&loop, path, &on_loaded, &loaded, &tracker)!!;
    while (!loaded.done) loop.run_once();
    assert(loaded.status == 0);
    assert(tracker.allocation_count() == 1, "Only the returned data remains allocated");
    alloc::free(&tracker, loaded.data.ptr);
}

struct ReadIntoState
{
    FileHandle* file;
    char[16] buffer;
    char[] got;
    bool read_done;
    bool closed;
}

fn void on_read_into(char[] data, int status, void* user_data)
{
    ReadIntoState* state = user_data;
    assert(status == 0);
    state.got = data;
    state.read_done = true;
    state.file.close(&on_closed, state)!!;
}

fn void on_closed(int status, void* user_data)
{
    ((ReadIntoState*)user_data).closed = true;
}

fn void on_opened(FileHandle* handle, int status, void* user_data)
{
    ReadIntoState* state = user_data;
    assert(status == 0);
    state.file = handle;
    handle.read_into(2, &state.buffer, &on_read_into, state)!!;
}

fn void test_read_into_caller_buffer() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;
    String path = test_support::temp_path("read_into.txt").copy(mem);
    defer free(path);
    std::io::file::save(path, "..payload")!!;
    defer (void)std::io::file::delete(path);

    ReadIntoState state;
    c3io::file::open(&loop, path, c3io::file::OPEN_RDONLY, 0, &on_opened, &state)!!;
    while (!state.closed) loop.run_once();
    assert(state.got.ptr == &state.buffer, "Data lands in the caller's buffer");
    assert((String)state.got == "payload");
}
