module c3io::event_loop_test;

import c3io;
import c3io::event_loop;
import c3io::uv;
import c3io::work;
import std::thread;
import std::time;
import std::io;

<*
 Test event loop creation and destruction.
*>
fn void test_event_loop_create_and_free() @test
{
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop successfully");
    }

    event_loop::EventLoop loop = loop_opt;
    defer loop.free()!!;

    assert(true, "Event loop created successfully");
}

<*
 Test running an empty event loop.
 Should return immediately since there are no active handles.
*>
fn void test_event_loop_run_empty() @test
{
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
    }

    event_loop::EventLoop loop = loop_opt;
    defer loop.free()!!;

    // Run empty loop - should return immediately
    (void)loop.run();

    assert(!loop.is_alive(), "Empty loop should not be alive after run");
}

<*
 Test event loop is_alive check.
*>
fn void test_event_loop_is_alive() @test
{
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
    }

    event_loop::EventLoop loop = loop_opt;
    defer loop.free()!!;

    // Empty loop should not be alive
    assert(!loop.is_alive(), "Empty loop should not be alive");
}

<*
 Test event loop run modes (nowait and once).
*>
fn void test_event_loop_run_modes() @test
{
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
    }

    event_loop::EventLoop loop = loop_opt;
    defer loop.free()!!;

    // Run in nowait mode - should return immediately
    bool alive = loop.run_nowait();
    assert(!alive, "Empty loop should not be alive after nowait");

    // Run once - should also return immediately
    alive = loop.run_once();
    assert(!alive, "Empty loop should not be alive after once");
}

fn void sleep_200ms(void* arg)
{
    thread::sleep_ms(200);
}

fn void on_work_done(void* arg, int status)
{
    *(int*)arg = status;
}

<*
 shutdown() returns false without blocking while work is running on the
 thread pool, free() refuses to release the loop meanwhile, and a later
 shutdown() finishes once the work is done.
*>
fn void test_shutdown_does_not_block_on_running_work() @test
{
    event_loop::EventLoop loop = event_loop::create()!!;

    int status = 1;
    work::queue(&loop, &sleep_200ms, &on_work_done, &status)!!;
    thread::sleep_ms(20);  // Let a pool thread pick the work up.

    Clock start = clock::now();
    assert(!loop.shutdown(), "Running work keeps the loop alive");
    assert(start.mark().to_ms() < 100, "shutdown must not wait for the work");
    if (try loop.free()) assert(false, "free() must refuse while work is running");
    assert(c3io::last_status() == uv::UV_EBUSY);

    int calls;
    while (!loop.shutdown())
    {
        thread::sleep_ms(5);
        calls++;
    }
    assert(calls > 1);
    assert(status == 0, "Work that had started completes normally");
    loop.free()!!;
}
