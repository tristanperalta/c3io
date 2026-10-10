module c3io::timer;

import c3io;
import c3io::uv;
import c3io::event_loop;

<*
 Async Timer Wrapper for libuv
 ==============================
 Provides async timer operations using libuv's timer API.

 Timers can be one-shot or repeating.

 Usage:
   Timer* timer = c3io::timer::create(loop);
   timer.start(1000, 0, &on_timeout, user_data);  // Fire once after 1 second
   // Later:
   timer.stop();
   timer.close();
*>

// Faults
excuse
{
    TIMER_INIT_FAILED,
    TIMER_START_FAILED,
}

// Callback types
alias TimeoutCallback = fn void(Timer* timer, void* user_data);

<*
 Timer handle.
 Wraps a libuv timer handle and provides async timer operations.
*>
struct Timer
{
    event_loop::HandleOwner owner;
    Allocator allocator;
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
    Timer* timer = uv::handle_get(Timer, handle);
    Allocator allocator = timer.allocator;
    alloc::free(allocator, handle);
    alloc::free(allocator, timer);
}

<*
 Create a new timer.

 @param loop : "Event loop to attach to"
 @param allocator : "Allocator for the timer (default: the loop's)"
*>
fn Timer*? create(event_loop::EventLoop* loop, Allocator allocator = null){
    allocator = loop.allocator_or(allocator);
    uv::Timer* handle = c3io::alloc_handle(allocator, uv::Timer, uv::HandleType.TIMER);

    int result = uv::timer_init(loop.loop, handle);
    if (result != 0)
    {
        alloc::free(allocator, handle);
        c3io::set_last_status(result);
        return TIMER_INIT_FAILED~;
    }

    Timer* timer = alloc::new(allocator, Timer);
    timer.owner.init(&on_close_internal);
    timer.allocator = allocator;
    timer.handle = handle;
    timer.loop = loop;

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
fn void? Timer.start(&self, ulong timeout_ms, ulong repeat_ms,
                    TimeoutCallback callback, void* user_data){
    self.callback = callback;
    self.user_data = user_data;

    int result = uv::timer_start(self.handle, &on_timer_internal, timeout_ms, repeat_ms);
    c3io::@check(result, TIMER_START_FAILED)!;
}

<*
 Stop the timer.
*>
fn void Timer.stop(&self){
    uv::timer_stop(self.handle);
}

<*
 Close the timer and free resources.
 Note: This is async - the timer and handle will be freed when the close completes.
*>
fn void Timer.close(&self){
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
fn void Timer.again(&self){
    uv::timer_again(self.handle);
}

<*
 Set the repeat interval for a timer.

 @param repeat_ms : "Repeat interval in milliseconds"
*>
fn void Timer.set_repeat(&self, ulong repeat_ms){
    uv::timer_set_repeat(self.handle, repeat_ms);
}

<*
 Get the repeat interval for a timer.

 @return "Repeat interval in milliseconds"
*>
fn ulong Timer.get_repeat(&self){
    return uv::timer_get_repeat(self.handle);
}
