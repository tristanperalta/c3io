module async::work;

import async::event_loop;
import uv;
import std::io;

<*
 Async Work (Thread Pool)
 =========================
 General-purpose wrapper for libuv's thread pool (uv_queue_work).

 Allows wrapping blocking CPU-intensive or I/O operations to run in
 background threads without blocking the event loop.

 Similar to JavaScript Promises - work runs in background, callback
 fires in main thread when complete.

 Usage:
   WorkContext* ctx = mem::new(WorkContext);
   ctx.input = my_data;
   ctx.work_fn = &my_blocking_function;
   ctx.callback = &my_completion_callback;
   ctx.user_data = user_ptr;

   queue_work(loop, ctx);
*>

// Callback types
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

 Note: This function is deprecated. Use EventLoop.queue_work() instead.

 @param loop : "Event loop"
 @param ctx : "Work context (caller must allocate)"
 @return "0 on success, negative error code on failure"
*>
fn int queue_work(event_loop::EventLoop* loop, event_loop::WorkContext* ctx) @public
{
    // Forward to EventLoop method
    return loop.queue_work(ctx);
}
