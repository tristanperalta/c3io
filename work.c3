module c3io::work;

import c3io;
import c3io::uv;
import c3io::event_loop;

<*
 Thread pool work
 ================
 Runs blocking or CPU-heavy functions on libuv's thread pool, then reports
 back on the loop thread.

 Threads:
 - `work` runs on a thread pool thread. It may block, but must not touch the
   loop or any c3io object, and must synchronize any memory it shares.
 - `after` runs on the loop thread, inside run()/run_nowait(), once `work`
   has returned. This is where results go back to the rest of the program,
   for example where an asset loader uploads a texture to the GPU.

 Usage:
   fn void decode(void* arg) { ... }                 // pool thread
   fn void upload(void* arg, int status) { ... }     // loop thread
   RequestId id = work::queue(loop, &decode, &upload, asset)!;
   // Later, if the result is no longer wanted:
   loop.cancel(id);  // true if it hadn't started; upload gets UV_ECANCELED

 The pool has 4 threads unless the UV_THREADPOOL_SIZE environment variable
 says otherwise, and is shared with file operations and DNS queries.
*>

excuse WORK_QUEUE_FAILED;

<*
 Runs on a thread pool thread.
*>
alias WorkFn = fn void(void* arg);

<*
 Runs on the loop thread after the work function returned (status 0), or
 instead of it if the work was cancelled (status UV_ECANCELED).
*>
alias AfterWorkFn = fn void(void* arg, int status);

struct WorkContext @private
{
    event_loop::PendingRequest pending;
    event_loop::EventLoop* loop;
    Allocator allocator;
    WorkFn work;
    AfterWorkFn after;
    void* arg;
    uv::Work* req;
}

fn void do_work(uv::Work* req) @private
{
    WorkContext* ctx = uv::req_get(WorkContext, req);
    ctx.work(ctx.arg);
}

fn void after_work(uv::Work* req, int status) @private
{
    WorkContext* ctx = uv::req_get(WorkContext, req);
    ctx.loop.untrack(&ctx.pending);
    AfterWorkFn after = ctx.after;
    void* arg = ctx.arg;
    alloc::free(ctx.allocator, ctx);
    if (after) after(arg, status);
}

<*
 Queue `work` to run on the thread pool, followed by `after` on the loop
 thread.

 @param loop : "Event loop"
 @param work : "Runs on a thread pool thread"
 @param after : "Runs on the loop thread afterwards (optional)"
 @param arg : "Passed to both functions"
 @param allocator : "Allocator for the request (default: the loop's)"
 @return "An id that can be passed to EventLoop.cancel()"
*>
fn event_loop::RequestId? queue(event_loop::EventLoop* loop, WorkFn work, AfterWorkFn after = null,
                                void* arg = null, Allocator allocator = null)
{
    allocator = loop.allocator_or(allocator);
    WorkContext* ctx = c3io::alloc_with_req(allocator, WorkContext, uv::ReqType.WORK);
    ctx.loop = loop;
    ctx.allocator = allocator;
    ctx.work = work;
    ctx.after = after;
    ctx.arg = arg;

    int result = uv::queue_work(loop.loop, ctx.req, work ? &do_work : null, &after_work);
    if (result != 0)
    {
        alloc::free(allocator, ctx);
        c3io::set_last_status(result);
        return WORK_QUEUE_FAILED~;
    }
    return loop.track(&ctx.pending, ctx.req);
}
