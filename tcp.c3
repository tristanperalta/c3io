module c3io::tcp;

import c3io;
import c3io::uv;
import c3io::event_loop;
import c3io::net;

<*
 Async TCP connections
 =====================
 A TcpConnection is either a connection to a peer or a listening server.

 Client:
   fn void on_connect(TcpConnection* conn, int status, void* user_data)
   {
       if (status != 0) return;  // conn is closed for you on failure
       conn.read_start(&on_read)!!;
       conn.write("hello")!!;
   }
   tcp::connect(loop, net::addr("127.0.0.1", 8080)!, &on_connect)!;

 Server:
   TcpConnection* server = tcp::create(loop)!;
   server.bind(net::addr("::", 8080)!)!;
   server.listen(128, &on_accept)!;

 Reading: without an allocate callback, a connection reads into one buffer of
 READ_BUFFER_SIZE bytes that it reuses. The `data` slice passed to the read
 callback is only valid until the callback returns. With an allocate
 callback, the buffers are the caller's and c3io never frees them.
*>

excuse
{
    TCP_INIT_FAILED,
    TCP_BIND_FAILED,
    TCP_LISTEN_FAILED,
    TCP_CONNECT_FAILED,
    TCP_READ_FAILED,
    TCP_WRITE_FAILED,
    TCP_WOULD_BLOCK,
    TCP_OPTION_FAILED,
}

<*
 Called when a connect completes. status is 0 on success or a negative libuv
 error. On failure the connection has already been closed.
*>
alias ConnectCallback = fn void(TcpConnection* conn, int status, void* user_data);

<*
 Called for each incoming connection (status 0, client set) or accept error
 (status < 0, client null). The client belongs to the callee, who must close
 it eventually.
*>
alias AcceptCallback = fn void(TcpConnection* server, int status, TcpConnection* client,
                               void* user_data);

<*
 Called with data (status 0), at end of stream (status UV_EOF) or on a read
 error (other negative status). `data.ptr` is the read buffer even when
 `data` is empty.
*>
alias ReadCallback = fn void(TcpConnection* conn, int status, char[] data, void* user_data);

<*
 Called when a queued write completes. status is 0 on success, UV_ECANCELED
 if the connection was closed first, or another negative libuv error.
*>
alias WriteCallback = fn void(TcpConnection* conn, int status, void* user_data);

<*
 Returns a buffer for the next read. The buffer belongs to the caller; it may
 be reused once the read callback for it has returned.
*>
alias AllocCallback = fn char[](TcpConnection* conn, usz suggested_size, void* user_data);

const usz READ_BUFFER_SIZE = 64 * 1024;

// Writes of up to WRITE_POOL_CAPACITY bytes reuse pooled requests.
const usz WRITE_POOL_CAPACITY = 4096;
const int WRITE_POOL_MAX = 64;

struct TcpConnection
{
    event_loop::HandleOwner owner;
    Allocator allocator;
    uv::Tcp* handle;
    event_loop::EventLoop* loop;
    AllocCallback alloc_cb;
    ReadCallback read_cb;
    void* read_user_data;
    AcceptCallback accept_cb;
    void* accept_user_data;
    char[] read_buffer;  // Reused for every read when alloc_cb is null
    RequestPool writes;
}

struct ConnectContext @private
{
    uv::Connect* req;
    TcpConnection* conn;
    ConnectCallback cb;
    void* user_data;
}

fn void on_close_internal(uv::Handle* handle) @private
{
    TcpConnection* conn = uv::handle_get(TcpConnection, handle);
    Allocator allocator = conn.allocator;
    conn.writes.free();
    if (conn.read_buffer.ptr) alloc::free(allocator, conn.read_buffer.ptr);
    alloc::free(allocator, handle);
    alloc::free(allocator, conn);
}

<*
 Create a TCP connection that isn't connected yet, to bind and listen on or
 to connect.

 @param loop : "Event loop to attach to"
 @param allocator : "Allocator for the connection and its buffers (default: the loop's)"
*>
fn TcpConnection*? create(event_loop::EventLoop* loop, Allocator allocator = null)
{
    allocator = loop.allocator_or(allocator);
    uv::Tcp* handle = c3io::alloc_handle(allocator, uv::Tcp, uv::HandleType.TCP);

    int result = uv::tcp_init(loop.loop, handle);
    if (result != 0)
    {
        alloc::free(allocator, handle);
        c3io::set_last_status(result);
        return TCP_INIT_FAILED~;
    }

    TcpConnection* conn = alloc::new(allocator, TcpConnection);
    conn.owner.init(&on_close_internal);
    conn.allocator = allocator;
    conn.handle = handle;
    conn.loop = loop;
    conn.writes.init(allocator, uv::ReqType.WRITE, WRITE_POOL_CAPACITY, WRITE_POOL_MAX);
    uv::handle_set(handle, conn);
    return conn;
}

fn void on_connect_internal(uv::Connect* req, int status) @private
{
    ConnectContext* ctx = uv::req_get(ConnectContext, req);
    TcpConnection* conn = ctx.conn;
    Allocator allocator = conn.allocator;
    ConnectCallback cb = ctx.cb;
    void* user_data = ctx.user_data;
    alloc::free(allocator, req);
    alloc::free(allocator, ctx);

    if (status < 0) conn.close();
    if (cb) cb(conn, status, user_data);
}

<*
 Connect to a remote address.

 @param loop : "Event loop"
 @param addr : "Remote address (resolve hostnames with c3io::dns first)"
 @param callback : "Called when the connection succeeds or fails"
 @param user_data : "Passed to the callback"
 @param allocator : "Allocator for the connection (default: the loop's)"
*>
fn TcpConnection*? connect(event_loop::EventLoop* loop, SocketAddr addr, ConnectCallback callback,
                           void* user_data = null, Allocator allocator = null)
{
    TcpConnection* conn = create(loop, allocator)!;

    uv::Connect* req = c3io::alloc_req(conn.allocator, uv::Connect, uv::ReqType.CONNECT);
    ConnectContext* ctx = alloc::new(conn.allocator, ConnectContext);
    *ctx = { .req = req, .conn = conn, .cb = callback, .user_data = user_data };
    uv::req_set(req, ctx);

    int result = uv::tcp_connect(req, conn.handle, addr.sockaddr(), &on_connect_internal);
    if (result != 0)
    {
        alloc::free(conn.allocator, req);
        alloc::free(conn.allocator, ctx);
        conn.close();
        c3io::set_last_status(result);
        return TCP_CONNECT_FAILED~;
    }
    return conn;
}

fn void on_alloc_internal(uv::Handle* handle, usz suggested_size, uv::Buf* buf) @private
{
    TcpConnection* conn = uv::handle_get(TcpConnection, handle);
    char[] target;
    if (conn.alloc_cb)
    {
        target = conn.alloc_cb(conn, suggested_size, conn.read_user_data);
    }
    else
    {
        if (!conn.read_buffer.ptr)
        {
            conn.read_buffer = alloc::new_array(conn.allocator, char, (sz)READ_BUFFER_SIZE);
        }
        target = conn.read_buffer;
    }
    *buf = c3io::make_buf(target.ptr, target.len);
}

fn void on_read_internal(uv::Stream* stream, sz nread, uv::Buf* buf) @private
{
    // nread == 0 is libuv's "would block": nothing to report.
    if (nread == 0) return;

    TcpConnection* conn = uv::handle_get(TcpConnection, stream);
    if (!conn.read_cb) return;

    char* base = (char*)buf.base;
    if (nread < 0)
    {
        conn.read_cb(conn, (int)nread, base[:0], conn.read_user_data);
        return;
    }
    conn.read_cb(conn, 0, base[:nread], conn.read_user_data);
}

<*
 Start reading from the connection.

 @param read_cb : "Called with data, at end of stream, or on error"
 @param user_data : "Passed to the callbacks"
 @param alloc_cb : "Supplies read buffers (optional; default: one reused internal buffer)"
*>
fn void? TcpConnection.read_start(&self, ReadCallback read_cb, void* user_data = null,
                                  AllocCallback alloc_cb = null)
{
    self.read_cb = read_cb;
    self.alloc_cb = alloc_cb;
    self.read_user_data = user_data;
    c3io::@check(uv::read_start((uv::Stream*)self.handle, &on_alloc_internal, &on_read_internal),
                 TCP_READ_FAILED)!;
}

<*
 Stop reading from the connection.
*>
fn void? TcpConnection.read_stop(&self)
{
    c3io::@check(uv::read_stop((uv::Stream*)self.handle), TCP_READ_FAILED)!;
}

fn void on_write_internal(uv::Write* req, int status) @private
{
    PooledRequest* r = uv::req_get(PooledRequest, req);
    TcpConnection* conn = r.owner;
    WriteCallback callback = (WriteCallback)r.callback;
    if (callback) callback(conn, status, r.user_data);
    conn.writes.release(r);
}

<*
 Write as much of `data` as the kernel takes right now, without allocating or
 queuing. Fails with TCP_WOULD_BLOCK if nothing could be written. A short
 write is possible; the caller sends the rest later or with write().

 @return "Number of bytes written"
*>
fn sz? TcpConnection.try_write(&self, char[] data)
{
    uv::Buf buf = c3io::make_buf(data.ptr, data.len);
    int result = uv::try_write((uv::Stream*)self.handle, &buf, 1);
    if (result >= 0) return result;
    c3io::set_last_status(result);
    if (result == uv::UV_EAGAIN) return TCP_WOULD_BLOCK~;
    return TCP_WRITE_FAILED~;
}

<*
 Queue data to write. The data is copied, so the caller can reuse it at once.
 Writes of up to WRITE_POOL_CAPACITY bytes reuse pooled memory. If the write
 can't be queued, it fails with a fault and the callback isn't called.

 @param data : "Bytes to write"
 @param callback : "Called when the write completes (optional)"
 @param user_data : "Passed to the callback"
*>
fn void? TcpConnection.write(&self, char[] data, WriteCallback callback = null, void* user_data = null)
{
    PooledRequest* r = self.writes.acquire(data);
    r.owner = self;
    r.callback = (void*)callback;
    r.user_data = user_data;

    int result = uv::write(r.req, (uv::Stream*)self.handle, &r.buf, 1, &on_write_internal);
    if (result != 0)
    {
        self.writes.release(r);
        c3io::set_last_status(result);
        return TCP_WRITE_FAILED~;
    }
}

<*
 Close the connection. Queued writes complete with UV_ECANCELED, then the
 connection is freed. Don't use the connection after calling this.
*>
fn void TcpConnection.close(&self)
{
    if (uv::is_closing(self.handle) != 0) return;
    uv::close((uv::Handle*)self.handle, &on_close_internal);
}

<*
 Enable or disable TCP_NODELAY. Enabling sends small messages immediately
 instead of batching them (Nagle's algorithm), which games usually want.
*>
fn void? TcpConnection.set_nodelay(&self, bool enable)
{
    c3io::@check(uv::tcp_nodelay(self.handle, enable ? 1 : 0), TCP_OPTION_FAILED)!;
}

<*
 Enable or disable TCP keepalive.

 @param enable : "True to enable keepalive"
 @param delay : "Initial delay in seconds (only used if enable is true)"
*>
fn void? TcpConnection.set_keepalive(&self, bool enable, uint delay = 60)
{
    c3io::@check(uv::tcp_keepalive(self.handle, enable ? 1 : 0, delay), TCP_OPTION_FAILED)!;
}

<*
 The local address of the connection or server.
*>
fn SocketAddr? TcpConnection.local_addr(&self)
{
    SocketAddr addr;
    int len = SocketAddr::size;
    c3io::@check(uv::tcp_getsockname(self.handle, addr.sockaddr(), &len), TCP_OPTION_FAILED)!;
    return addr;
}

<*
 The remote address of a connected connection.
*>
fn SocketAddr? TcpConnection.peer_addr(&self)
{
    SocketAddr addr;
    int len = SocketAddr::size;
    c3io::@check(uv::tcp_getpeername(self.handle, addr.sockaddr(), &len), TCP_OPTION_FAILED)!;
    return addr;
}

fn void on_connection_internal(uv::Stream* server, int status) @private
{
    TcpConnection* server_conn = uv::handle_get(TcpConnection, server);
    if (!server_conn.accept_cb) return;

    if (status < 0)
    {
        server_conn.accept_cb(server_conn, status, null, server_conn.accept_user_data);
        return;
    }

    TcpConnection*? client = create(server_conn.loop, server_conn.allocator);
    if (catch client)
    {
        server_conn.accept_cb(server_conn, c3io::last_status(), null, server_conn.accept_user_data);
        return;
    }

    int result = uv::accept(server, (uv::Stream*)client.handle);
    if (result != 0)
    {
        client.close();
        server_conn.accept_cb(server_conn, result, null, server_conn.accept_user_data);
        return;
    }
    server_conn.accept_cb(server_conn, 0, client, server_conn.accept_user_data);
}

<*
 Bind to a local address. Binding "::" also accepts IPv4 connections unless
 ipv6_only is set (on systems that support dual-stack sockets).

 @param addr : "Local address; port 0 lets the system choose"
 @param ipv6_only : "For an IPv6 address, don't accept IPv4 connections"
*>
fn void? TcpConnection.bind(&self, SocketAddr addr, bool ipv6_only = false)
{
    const uint UV_TCP_IPV6ONLY = 1;
    c3io::@check(uv::tcp_bind(self.handle, addr.sockaddr(), ipv6_only ? UV_TCP_IPV6ONLY : 0),
                 TCP_BIND_FAILED)!;
}

<*
 Start listening for incoming connections.

 @param backlog : "Maximum length of the queue of pending connections"
 @param callback : "Called for each new connection or accept error"
 @param user_data : "Passed to the callback"
*>
fn void? TcpConnection.listen(&self, int backlog, AcceptCallback callback, void* user_data = null)
{
    self.accept_cb = callback;
    self.accept_user_data = user_data;
    c3io::@check(uv::listen((uv::Stream*)self.handle, backlog, &on_connection_internal),
                 TCP_LISTEN_FAILED)!;
}
