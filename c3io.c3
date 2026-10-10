module c3io;

import c3io::uv;

<*
 Shared helpers for the c3io modules: libuv status reporting and allocation
 of libuv handles and requests.

 c3io never prints. Synchronous calls that fail return a fault and record the
 libuv status code, which `last_status()` returns. Asynchronous callbacks
 receive the libuv status code directly. Turn a code into text with
 `error_name()` or `error_message()`.
*>

tlocal int last_status_code;

<*
 The libuv status code recorded by the most recent c3io call that failed on
 this thread. 0 if no call has failed yet.
*>
fn int last_status() => last_status_code;

<*
 The libuv name of a status code, e.g. "EADDRINUSE".
*>
fn String error_name(int code) => ((ZString)uv::err_name(code)).str_view();

<*
 A human-readable description of a libuv status code.
*>
fn String error_message(int code) => ((ZString)uv::strerror(code)).str_view();

<*
 Record `result` and return `err` if it is a libuv error (negative).

 @param result : "Return value of a libuv call"
 @param err : "Fault to return on error"
*>
macro void? @check(int result, err)
{
    if (result < 0)
    {
        last_status_code = result;
        return err~;
    }
}

<*
 Record `result` as the last status code.
*>
fn void set_last_status(int result) => last_status_code = result;

<*
 A uv::Buf for `len` bytes at `base`. Windows buffers hold at most 4 GiB, so
 the length is clamped there; libuv then reports a short read or write.
*>
fn uv::Buf make_buf(void* base, usz len)
{
    $if env::WIN32:
        return { .base = base, .len = len > uint::max ? uint::max : (uint)len };
    $else
        return { .base = base, .len = len };
    $endif
}

<*
 Allocate zeroed memory for a libuv handle of the given type.
*>
macro alloc_handle(Allocator allocator, $Type, uv::HandleType type)
{
    return ($Type*)alloc::calloc(allocator, (sz)uv::handle_size(type));
}

<*
 Allocate zeroed memory for a libuv request of the given type.
*>
macro alloc_req(Allocator allocator, $Type, uv::ReqType type)
{
    return ($Type*)alloc::calloc(allocator, (sz)uv::req_size(type));
}

<*
 Allocate a zeroed context struct followed by a uv request of `type`, in one
 block. $Ctx must have a `req` field, which is set to the request; the
 request's data field points back at the context. Free the context to free
 both.
*>
macro alloc_with_req(Allocator allocator, $Ctx, uv::ReqType type)
{
    usz offset = align16($Ctx::size);
    char* block = alloc::calloc(allocator, (sz)(offset + uv::req_size(type)));
    $Ctx* ctx = ($Ctx*)block;
    ctx.req = (void*)(block + offset);
    uv::req_set(ctx.req, ctx);
    return ctx;
}

<*
 A uv request together with a copy of the data it sends, in one allocation:
 this struct, then the request, then the data.
*>
struct PooledRequest
{
    PooledRequest* next_free;
    usz capacity;     // Bytes of room for data
    void* req;        // The uv request; its data field points back here
    char* data;
    uv::Buf buf;      // The data copy, as passed to libuv
    void* owner;      // The socket or connection that queued it
    void* callback;   // The caller's completion callback
    void* user_data;
}

<*
 Recycles PooledRequests whose data fits pooled_capacity, so a socket that
 sends small messages steadily stops allocating once the pool is warm.
*>
struct RequestPool
{
    Allocator allocator;
    uv::ReqType type;
    usz pooled_capacity;
    int max_pooled;
    PooledRequest* free_list;
    int count;
}

fn void RequestPool.init(&self, Allocator allocator, uv::ReqType type, usz pooled_capacity,
                         int max_pooled)
{
    *self = { .allocator = allocator, .type = type, .pooled_capacity = pooled_capacity,
              .max_pooled = max_pooled };
}

macro usz align16(usz n) @private => (n + 15) & ~(usz)15;

<*
 Get a request whose buffer holds a copy of `data`.
*>
fn PooledRequest* RequestPool.acquire(&self, char[] data)
{
    PooledRequest* r;
    if (data.len <= self.pooled_capacity && self.free_list)
    {
        r = self.free_list;
        self.free_list = r.next_free;
        self.count--;
    }
    else
    {
        usz capacity = data.len <= self.pooled_capacity ? self.pooled_capacity : data.len;
        usz req_offset = align16(PooledRequest::size);
        usz data_offset = req_offset + align16(uv::req_size(self.type));
        char* block = alloc::calloc(self.allocator, (sz)(data_offset + capacity));
        r = (PooledRequest*)block;
        r.capacity = capacity;
        r.req = block + req_offset;
        r.data = block + data_offset;
        uv::req_set(r.req, r);
    }
    if (data.len) mem::copy(r.data, data.ptr, data.len);
    r.buf = make_buf(r.data, data.len);
    return r;
}

<*
 Return a request to the pool, or free it if the pool is full or the
 request is larger than pooled_capacity.
*>
fn void RequestPool.release(&self, PooledRequest* r)
{
    if (r.capacity == self.pooled_capacity && self.count < self.max_pooled)
    {
        r.next_free = self.free_list;
        self.free_list = r;
        self.count++;
        return;
    }
    alloc::free(self.allocator, r);
}

<*
 Free every pooled request.
*>
fn void RequestPool.free(&self)
{
    while (self.free_list)
    {
        PooledRequest* next = self.free_list.next_free;
        alloc::free(self.allocator, self.free_list);
        self.free_list = next;
    }
    self.count = 0;
}
