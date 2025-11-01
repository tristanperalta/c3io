module async::event_loop;

import uv;
import std::io;

<*
 Event Loop Wrapper for libuv
 =============================
 Provides an idiomatic C3 interface for libuv's event loop.

 The event loop is the core of async I/O in libuv. It runs callbacks
 when I/O operations complete, timers expire, etc.

 Usage:
   EventLoop? loop = event_loop::create();
   defer loop.free();

   // Add handles (TCP sockets, timers, etc.) to the loop

   loop.run();  // Blocks until no more events
*>

// Faults
faultdef EVENT_LOOP_INIT_FAILED;
faultdef EVENT_LOOP_RUN_FAILED;
faultdef EVENT_LOOP_CLOSE_FAILED;
faultdef EVENT_LOOP_STILL_ACTIVE;

<*
 Event loop wrapper.
 Manages libuv event loop lifecycle.
*>
struct EventLoop
{
    uv::Loop* loop;
}

<*
 Create and initialize an event loop.
*>
fn EventLoop? create() @public
{
    // Allocate loop structure
    usz loop_size = uv::loop_size();
    uv::Loop* loop = mem::new_array(char, loop_size);

    // Initialize the loop
    int result = uv::loop_init(loop);
    if (result != 0)
    {
        free(loop);
        io::printfn("Failed to initialize event loop: %s", (ZString)uv::strerror(result));
        return EVENT_LOOP_INIT_FAILED?;
    }

    return (EventLoop){ loop };
}

<*
 Run the event loop until there are no more active handles.
 This blocks until all async operations complete.
*>
fn void? EventLoop.run(&self) @public
{
    int result = uv::run(self.loop, uv::RunMode.DEFAULT);
    uv::@uv_check(result, "Event loop run failed", EVENT_LOOP_RUN_FAILED)!;
}

<*
 Run the event loop in non-blocking mode (process pending events only).
 Returns true if there are still active handles, false otherwise.
*>
fn bool EventLoop.run_nowait(&self) @public
{
    int result = uv::run(self.loop, uv::RunMode.NOWAIT);
    return uv::loop_alive(self.loop) != 0;
}

<*
 Run the event loop once (process one event).
 Returns true if there are still active handles, false otherwise.
*>
fn bool EventLoop.run_once(&self) @public
{
    uv::run(self.loop, uv::RunMode.ONCE);
    return uv::loop_alive(self.loop) != 0;
}

<*
 Stop the event loop.
 Causes run() to return at the earliest safe point.
*>
fn void EventLoop.stop(&self) @public
{
    uv::stop(self.loop);
}

<*
 Check if the event loop has active handles or requests.
 Returns true if there are active operations, false otherwise.
*>
fn bool EventLoop.is_alive(&self) @public
{
    return uv::loop_alive(self.loop) != 0;
}

<*
 Close and free the event loop.
 All handles must be closed before calling this.
*>
fn void? EventLoop.close(&self) @public
{
    int result = uv::loop_close(self.loop);
    if (result != 0)
    {
        io::printfn("Failed to close event loop: %s", (ZString)uv::strerror(result));
        if (result == -16)  // UV_EBUSY
        {
            return EVENT_LOOP_STILL_ACTIVE?;
        }
        return EVENT_LOOP_CLOSE_FAILED?;
    }
}

<*
 Free the event loop (close and deallocate).
 This is the main cleanup method.
*>
fn void EventLoop.free(&self) @public
{
    // Try to close the loop
    if (catch err = self.close())
    {
        io::printfn("Warning: Error closing event loop during free: %s", err);
    }

    // Free the memory
    free(self.loop);
}

// Thread Pool / Work Queue Support
// =================================

// Callback types for thread pool work
alias WorkFunction = fn void(void* input, void** output);  // Runs in thread pool
alias CompletionCallback = fn void(void* output, int status, void* user_data);  // Runs in event loop

<*
 Work context - holds all data for a thread pool operation.
*>
struct WorkContext
{
    uv::Work* work_req;        // libuv work request handle
    void* input;               // Input data (read by worker thread)
    void* output;              // Output data (set by worker thread, read by callback)
    WorkFunction work_fn;      // Function to run in thread pool
    CompletionCallback callback;  // Completion callback in event loop
    void* user_data;           // User data passed to callback
    int error;                 // Error code (0 = success)
}

<*
 Internal callback - runs in THREAD POOL thread.
 This is safe to block! We're not in the event loop.
*>
fn void do_work_in_thread_pool(uv::Work* req)
{
    WorkContext* ctx = (WorkContext*)uv::req_get_data((uv::Req*)req);

    if (ctx.work_fn)
    {
        // Call user's work function - CAN BLOCK safely!
        ctx.work_fn(ctx.input, &ctx.output);
    }
}

<*
 Internal callback - runs in EVENT LOOP thread after work completes.
 This must NOT block - we're back in the main event loop.
*>
fn void after_work_in_event_loop(uv::Work* req, int status)
{
    WorkContext* ctx = (WorkContext*)uv::req_get_data((uv::Req*)req);

    // Store status
    ctx.error = status;

    // Clean up work request BEFORE calling callback
    // This allows the callback to safely free the WorkContext
    free(ctx.work_req);
    ctx.work_req = null;

    // Call user completion callback in event loop thread
    if (ctx.callback)
    {
        ctx.callback(ctx.output, status, ctx.user_data);
    }

    // Note: We don't free ctx itself - the user might still need output data
    // The user is responsible for freeing ctx when done with output
}

<*
 Queue work to run in thread pool.

 The work function runs in a background thread and can safely block.
 The completion callback runs in the event loop thread when work is done.

 @param ctx : "Work context (caller must allocate)"
 @return "0 on success, negative error code on failure"
*>
fn int EventLoop.queue_work(&self, WorkContext* ctx) @public
{
    // Allocate uv_work_t handle
    ctx.work_req = mem::new_array(char, 512);  // Enough for uv_work_t
    uv::req_set_data((uv::Req*)ctx.work_req, ctx);

    // Queue work
    int result = uv::queue_work(self.loop, ctx.work_req,
                                  &do_work_in_thread_pool,
                                  &after_work_in_event_loop);

    if (result != 0)
    {
        io::printfn("Failed to queue work: %s", (ZString)uv::strerror(result));
        free(ctx.work_req);
        ctx.work_req = null;
        return result;
    }

    return 0;
}
