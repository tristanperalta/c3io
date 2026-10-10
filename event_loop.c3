module c3io::event_loop;

import c3io;
import c3io::uv;

<*
 Event Loop Wrapper for libuv
 =============================
 Provides an idiomatic C3 interface for libuv's event loop.

 The event loop is the core of async I/O in libuv. It runs callbacks
 when I/O operations complete, timers expire, etc.

 Usage:
   EventLoop loop = event_loop::create()!;

   // Each frame: process whatever is ready, without blocking.
   loop.run_nowait();

   // On exit: close everything, possibly over several frames.
   while (!loop.shutdown()) { ... next frame ... }
   loop.free()!;
*>

// Faults
excuse
{
    EVENT_LOOP_INIT_FAILED,
    EVENT_LOOP_RUN_FAILED,
    EVENT_LOOP_CLOSE_FAILED,
    EVENT_LOOP_STILL_ACTIVE,
}

<*
 Event loop wrapper.
 Manages the libuv loop and the allocator its objects use by default.

 Handles and requests keep a pointer to their EventLoop, so don't move or copy
 an EventLoop after creating objects on it.
*>
struct EventLoop
{
    uv::Loop* loop;
    Allocator allocator;
    PendingRequest* pending;  // In-flight cancellable requests
    RequestId next_request_id;
}

<*
 Identifies an in-flight request (file operation, work item, DNS query) so it
 can be cancelled. Ids are never reused, so a stale id is harmless.
*>
typedef RequestId = ulong;

<*
 Link in the loop's list of in-flight requests. Embedded in each request
 context; see EventLoop.track().
*>
struct PendingRequest
{
    PendingRequest* prev;
    PendingRequest* next;
    uv::Req* req;
    RequestId id;
    bool cancelled;
}

<*
 First field of every c3io handle wrapper (UdpSocket, TcpConnection, Timer...).
 The uv handle's data points at the wrapper, so code that only has the uv
 handle, such as the loop's shutdown walk, can close it properly.
*>
struct HandleOwner
{
    uint magic;  // HANDLE_OWNER_MAGIC; marks the handle data as a HandleOwner
    uv::CloseCb close_cb;
}

const uint HANDLE_OWNER_MAGIC = 0xC310_0E3E;

<*
 Initialize the HandleOwner header of a wrapper.
*>
fn void HandleOwner.init(&self, uv::CloseCb close_cb)
{
    self.magic = HANDLE_OWNER_MAGIC;
    self.close_cb = close_cb;
}

<*
 Create and initialize an event loop.

 @param allocator : "Allocator for the loop and, by default, everything created on it"
*>
fn EventLoop? create(Allocator allocator = mem){
    uv::Loop* loop = alloc::calloc(allocator, (sz)uv::loop_size());

    int result = uv::loop_init(loop);
    if (result != 0)
    {
        alloc::free(allocator, loop);
        c3io::set_last_status(result);
        return EVENT_LOOP_INIT_FAILED~;
    }

    return { .loop = loop, .allocator = allocator };
}

<*
 The allocator an object on this loop should use: `allocator` if given,
 otherwise the loop's.
*>
fn Allocator EventLoop.allocator_or(&self, Allocator allocator)
{
    if (allocator) return allocator;
    return self.allocator;
}

<*
 Register an in-flight request and return its id.

 @param entry : "Link embedded in the request's context"
 @param req : "The uv request"
*>
fn RequestId EventLoop.track(&self, PendingRequest* entry, void* req)
{
    entry.req = req;
    entry.id = ++self.next_request_id;
    entry.cancelled = false;
    entry.prev = null;
    entry.next = self.pending;
    if (self.pending) self.pending.prev = entry;
    self.pending = entry;
    return entry.id;
}

<*
 Remove a completed request from the in-flight list.
*>
fn void EventLoop.untrack(&self, PendingRequest* entry)
{
    if (entry.prev)
    {
        entry.prev.next = entry.next;
    }
    else if (self.pending == entry)
    {
        self.pending = entry.next;
    }
    if (entry.next) entry.next.prev = entry.prev;
    entry.prev = null;
    entry.next = null;
}

<*
 Run the event loop until there are no more active handles.
 This blocks until all async operations complete.
*>
fn void? EventLoop.run(&self){
    int result = uv::run(self.loop, uv::RunMode.DEFAULT);
    c3io::@check(result, EVENT_LOOP_RUN_FAILED)!;
}

<*
 Run the event loop in non-blocking mode (process pending events only).
 Returns true if there are still active handles, false otherwise.
*>
fn bool EventLoop.run_nowait(&self){
    uv::run(self.loop, uv::RunMode.NOWAIT);
    return uv::loop_alive(self.loop) != 0;
}

<*
 Run the event loop once (process one event).
 Returns true if there are still active handles, false otherwise.
*>
fn bool EventLoop.run_once(&self){
    uv::run(self.loop, uv::RunMode.ONCE);
    return uv::loop_alive(self.loop) != 0;
}

<*
 Stop the event loop.
 Causes run() to return at the earliest safe point.
*>
fn void EventLoop.stop(&self){
    uv::stop(self.loop);
}

<*
 Check if the event loop has active handles or requests.
 Returns true if there are active operations, false otherwise.
*>
fn bool EventLoop.is_alive(&self){
    return uv::loop_alive(self.loop) != 0;
}

<*
 Walk callback for closing all handles.
 Closes each handle that isn't already closing. A c3io handle is closed with
 its owner's close callback, which frees the uv handle and the wrapper. Any
 other handle is closed without a callback; its memory belongs to whoever
 created it.
*>
fn void close_walk_cb(uv::Handle* handle, void* arg)
{
    if (uv::is_closing(handle) != 0) return;
    HandleOwner* owner = uv::handle_get_data(handle);
    if (owner && owner.magic == HANDLE_OWNER_MAGIC)
    {
        uv::close(handle, owner.close_cb);
        return;
    }
    uv::close(handle, null);
}

<*
 Cancel an in-flight request (file operation, work item or DNS query).

 Only a request that hasn't started on libuv's thread pool can be cancelled.
 Its callback then runs with UV_ECANCELED.

 @param id : "Id returned when the request was started"
 @return "True if the request was cancelled; false if it is running, finished or unknown"
*>
fn bool EventLoop.cancel(&self, RequestId id)
{
    for (PendingRequest* entry = self.pending; entry; entry = entry.next)
    {
        if (entry.id != id) continue;
        if (entry.cancelled || uv::cancel(entry.req) != 0) return false;
        entry.cancelled = true;
        return true;
    }
    return false;
}

<*
 Shut the loop down without blocking.

 Cancels every request that hasn't started, closes every handle that isn't
 closed yet, then runs at most `max_iterations` non-blocking iterations to
 deliver the resulting callbacks. Returns true once nothing is left, after
 which free() succeeds.

 Work already running on the thread pool can't be interrupted. While it runs
 this returns false; call it again on a later frame until it returns true.

 @param max_iterations : "Upper bound on non-blocking loop iterations"
 @return "True if the loop has nothing left to do"
*>
fn bool EventLoop.shutdown(&self, int max_iterations = 64)
{
    for (PendingRequest* entry = self.pending; entry; entry = entry.next)
    {
        if (!entry.cancelled && uv::cancel(entry.req) == 0) entry.cancelled = true;
    }
    uv::walk(self.loop, &close_walk_cb, null);
    for (int i = 0; i < max_iterations && self.is_alive(); i++)
    {
        uv::run(self.loop, uv::RunMode.NOWAIT);
    }
    return !self.is_alive();
}

<*
 Close the libuv loop. Fails with EVENT_LOOP_STILL_ACTIVE while handles or
 requests remain; use shutdown() first.
*>
fn void? EventLoop.close(&self){
    if (!self.loop) return;
    int result = uv::loop_close(self.loop);
    if (result != 0)
    {
        c3io::set_last_status(result);
        if (result == uv::UV_EBUSY) return EVENT_LOOP_STILL_ACTIVE~;
        return EVENT_LOOP_CLOSE_FAILED~;
    }
}

<*
 Close the loop and release its memory. Fails with EVENT_LOOP_STILL_ACTIVE,
 and keeps the loop usable, while handles or requests remain; use shutdown()
 first. Freeing a loop with work still running would let that work's
 completion touch freed memory.
*>
fn void? EventLoop.free(&self){
    if (!self.loop) return;
    self.close()!;
    alloc::free(self.allocator, self.loop);
    self.loop = null;
}
