module async::timer;

import uv;
import std::io;
import async::event_loop;

<*
 Async Timer Wrapper for libuv
 ==============================
 Provides async timer operations using libuv's timer API.

 Timers can be one-shot or repeating.

 Usage:
   Timer* timer = async::timer::create(loop);
   timer.start(1000, 0, &on_timeout, user_data);  // Fire once after 1 second
   // Later:
   timer.stop();
   timer.close();
*>

// Faults
faultdef TIMER_INIT_FAILED;
faultdef TIMER_START_FAILED;

// Callback types
alias TimeoutCallback = fn void(Timer* timer, void* user_data);

<*
 Timer handle.
 Wraps a libuv timer handle and provides async timer operations.
*>
struct Timer
{
    uv::Timer* handle;
    event_loop::EventLoop* loop;
    TimeoutCallback callback;
    void* user_data;
}

// Internal libuv callback wrappers
fn void on_timer_internal(uv::Timer* handle)
{
    Timer* timer = uv::handle_get(Timer, handle);

    if (timer.callback)
    {
        timer.callback(timer, timer.user_data);
    }
}

fn void on_close_internal(uv::Handle* handle)
{
    // Get timer from handle and free both
    Timer* timer = uv::handle_get(Timer, handle);
    free(handle);
    if (timer != null)
    {
        free(timer);
    }
}

<*
 Create a new timer.

 @param loop : "Event loop to attach to"
*>
fn Timer*? create(event_loop::EventLoop* loop) @public
{
    // Allocate timer handle
    uv::Timer* handle = uv::alloc_handle(uv::Timer, uv::HandleType.TIMER);

    // Initialize timer handle
    int result = uv::timer_init(loop.loop, handle);
    if (result != 0)
    {
        free(handle);
        io::printfn("Failed to initialize timer handle: %s", (ZString)uv::strerror(result));
        return TIMER_INIT_FAILED?;
    }

    Timer* timer = mem::new(Timer);
    timer.handle = handle;
    timer.loop = loop;
    timer.callback = null;
    timer.user_data = null;

    // Store timer pointer in handle's data field
    uv::handle_set(handle, timer);

    return timer;
}

<*
 Start the timer.

 @param timeout_ms : "Initial timeout in milliseconds"
 @param repeat_ms : "Repeat interval in milliseconds (0 for one-shot timer)"
 @param callback : "Callback to invoke on timeout"
 @param user_data : "User data passed to callback"
*>
fn void Timer.start(&self, ulong timeout_ms, ulong repeat_ms,
                    TimeoutCallback callback, void* user_data) @public
{
    self.callback = callback;
    self.user_data = user_data;

    int result = uv::timer_start(self.handle, &on_timer_internal, timeout_ms, repeat_ms);
    if (result != 0)
    {
        io::printfn("Failed to start timer: %s", (ZString)uv::strerror(result));
    }
}

<*
 Stop the timer.
*>
fn void Timer.stop(&self) @public
{
    uv::timer_stop(self.handle);
}

<*
 Close the timer and free resources.
 Note: This is async - the timer and handle will be freed when the close completes.
*>
fn void Timer.close(&self) @public
{
    // Stop timer first
    uv::timer_stop(self.handle);

    // Close handle (async operation that will free both handle and timer via callback)
    uv::close((uv::Handle*)self.handle, &on_close_internal);
    // Note: Both handle and timer will be freed by the callback
}

<*
 Restart a repeating timer.
 If the timer was stopped, this restarts it using the repeat value as the timeout.
*>
fn void Timer.again(&self) @public
{
    uv::timer_again(self.handle);
}

<*
 Set the repeat interval for a timer.

 @param repeat_ms : "Repeat interval in milliseconds"
*>
fn void Timer.set_repeat(&self, ulong repeat_ms) @public
{
    uv::timer_set_repeat(self.handle, repeat_ms);
}

<*
 Get the repeat interval for a timer.

 @return "Repeat interval in milliseconds"
*>
fn ulong Timer.get_repeat(&self) @public
{
    return uv::timer_get_repeat(self.handle);
}
