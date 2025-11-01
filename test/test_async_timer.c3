module async::timer::test;

import async::timer;
import async::event_loop;
import std::io;

// Test result tracking
struct TestContext
{
    bool success;
    bool completed;
    int call_count;
    event_loop::EventLoop* loop;
}

// ============================================================================
// One-shot Timer Tests
// ============================================================================

fn void on_oneshot_timer(async::timer::Timer* timer, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.call_count++;
    ctx.completed = true;
    ctx.success = true;
}

fn void test_oneshot_timer() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.call_count = 0;
    ctx.loop = &loop;

    // Create timer
    async::timer::Timer*? timer_opt = async::timer::create(&loop);
    if (catch err = timer_opt)
    {
        assert(false, "Should create timer");
        return;
    }
    async::timer::Timer* timer = timer_opt;

    // Start one-shot timer (100ms, no repeat)
    timer.start(100, 0, &on_oneshot_timer, &ctx);

    // Run event loop until timer fires
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Timer should fire");
    assert(ctx.call_count == 1, "Timer should fire exactly once");

    // Clean up
    timer.close();

    // Run loop until close completes
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Repeating Timer Tests
// ============================================================================

fn void on_repeat_timer(async::timer::Timer* timer, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.call_count++;

    // Stop after 3 calls
    if (ctx.call_count >= 3)
    {
        timer.stop();
        ctx.completed = true;
        ctx.success = true;
    }
}

fn void test_repeating_timer() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.call_count = 0;
    ctx.loop = &loop;

    async::timer::Timer*? timer_opt = async::timer::create(&loop);
    if (catch err = timer_opt)
    {
        assert(false, "Should create timer");
        return;
    }
    async::timer::Timer* timer = timer_opt;

    // Start repeating timer (50ms initial, 50ms repeat)
    timer.start(50, 50, &on_repeat_timer, &ctx);

    // Run event loop until we get 3 calls
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Timer should fire multiple times");
    assert(ctx.call_count == 3, "Timer should fire exactly 3 times");

    // Clean up
    timer.close();

    // Run loop until close completes
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Stop Timer Tests
// ============================================================================

fn void on_should_not_fire(async::timer::Timer* timer, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.call_count++;
    ctx.success = false;  // Should not be called
}

fn void test_stop_timer() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    TestContext ctx;
    ctx.success = true;  // Start as true, callback sets to false
    ctx.completed = false;
    ctx.call_count = 0;
    ctx.loop = &loop;

    async::timer::Timer*? timer_opt = async::timer::create(&loop);
    if (catch err = timer_opt)
    {
        assert(false, "Should create timer");
        return;
    }
    async::timer::Timer* timer = timer_opt;

    // Start timer
    timer.start(100, 0, &on_should_not_fire, &ctx);

    // Immediately stop it
    timer.stop();

    // Run loop for a bit to ensure timer doesn't fire
    for (int i = 0; i < 10; i++)
    {
        loop.run_once();
    }

    assert(ctx.success, "Stopped timer should not fire");
    assert(ctx.call_count == 0, "Callback should not be called");

    // Clean up
    timer.close();

    // Run loop until close completes
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Set/Get Repeat Tests
// ============================================================================

fn void test_set_get_repeat() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    async::timer::Timer*? timer_opt = async::timer::create(&loop);
    if (catch err = timer_opt)
    {
        assert(false, "Should create timer");
        return;
    }
    async::timer::Timer* timer = timer_opt;

    // Set repeat interval
    timer.set_repeat(500);

    // Get repeat interval
    ulong repeat = timer.get_repeat();

    assert(repeat == 500, "Repeat interval should be 500ms");

    // Clean up
    timer.close();

    // Run loop until close completes
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Timer Again Tests
// ============================================================================

fn void on_again_timer(async::timer::Timer* timer, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.call_count++;

    if (ctx.call_count == 1)
    {
        // Stop after first call
        timer.stop();
    }
    else if (ctx.call_count == 2)
    {
        // Second call after 'again' - we're done
        ctx.completed = true;
        ctx.success = true;
        timer.stop();
    }
}

fn void test_timer_again() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.call_count = 0;
    ctx.loop = &loop;

    async::timer::Timer*? timer_opt = async::timer::create(&loop);
    if (catch err = timer_opt)
    {
        assert(false, "Should create timer");
        return;
    }
    async::timer::Timer* timer = timer_opt;

    // Set repeat interval
    timer.set_repeat(50);

    // Start with same repeat value
    timer.start(50, 50, &on_again_timer, &ctx);

    // Run until first call
    while (ctx.call_count < 1)
    {
        loop.run_once();
    }

    // Timer is now stopped by callback. Restart it with 'again'
    timer.again();

    // Run until second call
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Timer 'again' should work");
    assert(ctx.call_count == 2, "Timer should fire twice");

    // Clean up
    timer.close();

    // Run loop until close completes
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Multiple Timers Tests
// ============================================================================

struct MultiTimerContext
{
    int timer1_count;
    int timer2_count;
    bool completed;
    event_loop::EventLoop* loop;
}

fn void on_multi_timer1(async::timer::Timer* timer, void* user_data)
{
    MultiTimerContext* ctx = (MultiTimerContext*)user_data;
    ctx.timer1_count++;

    if (ctx.timer1_count >= 2 && ctx.timer2_count >= 2)
    {
        ctx.completed = true;
        timer.stop();
    }
}

fn void on_multi_timer2(async::timer::Timer* timer, void* user_data)
{
    MultiTimerContext* ctx = (MultiTimerContext*)user_data;
    ctx.timer2_count++;

    if (ctx.timer1_count >= 2 && ctx.timer2_count >= 2)
    {
        ctx.completed = true;
        timer.stop();
    }
}

fn void test_multiple_timers() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    MultiTimerContext ctx;
    ctx.timer1_count = 0;
    ctx.timer2_count = 0;
    ctx.completed = false;
    ctx.loop = &loop;

    // Create two timers
    async::timer::Timer*? timer1_opt = async::timer::create(&loop);
    if (catch err = timer1_opt)
    {
        assert(false, "Should create timer1");
        return;
    }
    async::timer::Timer* timer1 = timer1_opt;

    async::timer::Timer*? timer2_opt = async::timer::create(&loop);
    if (catch err = timer2_opt)
    {
        assert(false, "Should create timer2");
        return;
    }
    async::timer::Timer* timer2 = timer2_opt;

    // Start both timers with different intervals
    timer1.start(50, 50, &on_multi_timer1, &ctx);
    timer2.start(75, 75, &on_multi_timer2, &ctx);

    // Run until both have fired at least twice
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.timer1_count >= 2, "Timer1 should fire at least twice");
    assert(ctx.timer2_count >= 2, "Timer2 should fire at least twice");

    // Clean up
    timer1.stop();
    timer2.stop();
    timer1.close();
    timer2.close();

    // Run loop until close completes
    while (loop.is_alive())
    {
        loop.run_once();
    }
}
