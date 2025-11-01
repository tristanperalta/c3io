module async::event_loop_test;

import async::event_loop;
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
        return;
    }

    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

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
        return;
    }

    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

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
        return;
    }

    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

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
        return;
    }

    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Run in nowait mode - should return immediately
    bool alive = loop.run_nowait();
    assert(!alive, "Empty loop should not be alive after nowait");

    // Run once - should also return immediately
    alive = loop.run_once();
    assert(!alive, "Empty loop should not be alive after once");
}
