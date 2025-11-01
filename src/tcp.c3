module async::tcp;

import uv;
import std::io;
import async::event_loop;

<*
 Async TCP Socket Wrapper for libuv
 ==================================
 Provides async TCP connection and I/O operations using libuv.

 Usage:
   TcpConnection? conn = async_tcp::connect(loop, "127.0.0.1", 8080, &on_connect);
   defer conn.close();

   // In on_connect callback:
   conn.start_read(&on_alloc, &on_read);
   conn.write(data, &on_write);
*>

// Faults
faultdef TCP_INIT_FAILED;
faultdef TCP_CONNECT_FAILED;
faultdef TCP_READ_FAILED;
faultdef TCP_WRITE_FAILED;
faultdef TCP_ADDR_PARSE_FAILED;

<*
 TCP connection state.
 Wraps a libuv TCP handle and provides async I/O.
*>
struct TcpConnection
{
    uv::Tcp* handle;
    event_loop::EventLoop* loop;
    AllocCallback alloc_cb;
    ReadCallback read_cb;
    void* read_user_data;
}

// Callback types for user code (defined before structs that use them)
alias ConnectCallback = fn void(TcpConnection* conn, int status, void* user_data);
alias ReadCallback = fn void(TcpConnection* conn, char[] data, void* user_data);
alias WriteCallback = fn void(TcpConnection* conn, int status, void* user_data);
alias AllocCallback = fn char[](TcpConnection* conn, usz suggested_size, void* user_data);

<*
 Connection context for async connect.
 Stores the connect request and callback.
*>
struct ConnectContext
{
    uv::Connect* req;
    TcpConnection* conn;
    ConnectCallback cb;
    void* user_data;
}

<*
 Write context for async write.
 Stores the write request and callback.
*>
struct WriteContext
{
    uv::Write* req;
    TcpConnection* conn;
    WriteCallback cb;
    void* user_data;
    uv::Buf* bufs;  // Keep buffers alive until write completes
}

<*
 Create a new TCP connection (not yet connected).

 @param loop: "Event loop to attach to"
*>
fn TcpConnection*? create(event_loop::EventLoop* loop) @public
{
    // Allocate TCP handle
    uv::Tcp* handle = uv::alloc_handle(uv::Tcp, uv::HandleType.TCP);

    // Initialize TCP handle
    int result = uv::tcp_init(loop.loop, handle);
    if (result != 0)
    {
        free(handle);
        io::printfn("Failed to initialize TCP handle: %s", (ZString)uv::strerror(result));
        return TCP_INIT_FAILED?;
    }

    TcpConnection* conn = mem::new(TcpConnection);
    conn.handle = handle;
    conn.loop = loop;

    // Store connection pointer in handle's data field
    // This allows us to get back to TcpConnection from callbacks
    uv::handle_set(handle, conn);

    return conn;
}

<*
 Internal callback when libuv connect completes.
 Calls user's ConnectCallback.
*>
fn void on_connect_internal(uv::Connect* req, int status)
{
    ConnectContext* ctx = uv::req_get(ConnectContext, req);

    if (ctx.cb != null)
    {
        ctx.cb(ctx.conn, status, ctx.user_data);
    }

    // Free the connect context and request (but NOT the connection)
    free(ctx);
    free(req);
}

<*
 Connect to a remote TCP endpoint asynchronously.

 @param loop: "Event loop"
 @param host: "Hostname or IP address"
 @param port: "Port number"
 @param callback: "Called when connection completes (success or failure)"
 @param user_data: "User context passed to callback"
*>
fn TcpConnection*? connect(event_loop::EventLoop* loop, String host, ushort port,
                            ConnectCallback callback, void* user_data = null) @public
{
    // Create connection
    TcpConnection*? conn_opt = create(loop);
    if (catch err = conn_opt)
    {
        return err?;
    }
    TcpConnection* conn = conn_opt;

    // Parse address
    uv::Sockaddr_in addr;
    ZString host_z = (ZString)host;
    int result = uv::ip4_addr(host_z, (int)port, &addr);
    if (result != 0)
    {
        free(conn.handle);
        free(conn);
        io::printfn("Failed to parse address %s:%d: %s", host, port, (ZString)uv::strerror(result));
        return TCP_ADDR_PARSE_FAILED?;
    }

    // Allocate connect request and context (freed in callback)
    uv::Connect* req = uv::alloc_req(uv::Connect);
    ConnectContext* ctx = mem::new(ConnectContext);
    ctx.conn = conn;
    ctx.cb = callback;
    ctx.user_data = user_data;

    // Store context in request's data field
    uv::req_set(req, ctx);

    // Initiate async connect
    result = uv::tcp_connect(req, conn.handle,
                             (uv::Sockaddr*)&addr, &on_connect_internal);
    if (result != 0)
    {
        free(req);
        free(ctx);
        free(conn.handle);
        free(conn);
        io::printfn("Failed to initiate connect: %s", (ZString)uv::strerror(result));
        return TCP_CONNECT_FAILED?;
    }

    return conn;
}

<*
 Internal allocation callback for libuv read.
 Calls user's AllocCallback to get a buffer.
*>
fn void on_alloc_internal(uv::Handle* handle, usz suggested_size, uv::Buf* buf)
{
    // Get connection from handle's data field
    TcpConnection* conn = uv::handle_get(TcpConnection, handle);
    if (conn == null)
    {
        // Fallback: allocate default buffer
        char[] default_buf = mem::new_array(char, suggested_size);
        buf.base = default_buf.ptr;
        buf.len = default_buf.len;
        return;
    }

    if (conn.alloc_cb != null)
    {
        char[] user_buf = conn.alloc_cb(conn, suggested_size, conn.read_user_data);
        buf.base = user_buf.ptr;
        buf.len = user_buf.len;
    }
    else
    {
        // Default: allocate suggested size
        char[] default_buf = mem::new_array(char, suggested_size);
        buf.base = default_buf.ptr;
        buf.len = default_buf.len;
    }
}

<*
 Internal read callback for libuv.
 Calls user's ReadCallback with data.
*>
fn void on_read_internal(uv::Stream* stream, isz nread, uv::Buf* buf)
{
    // Get connection from handle's data field
    TcpConnection* conn = uv::handle_get(TcpConnection, stream);
    if (conn == null)
    {
        // Free buffer and return
        if (buf.base != null) free(buf.base);
        return;
    }

    if (nread > 0)
    {
        // Data received - construct slice from pointer and length
        char[] data = buf.base[:nread];

        if (conn.read_cb != null)
        {
            conn.read_cb(conn, data, conn.read_user_data);
        }
    }
    else if (nread == uv::UV_EOF)
    {
        // End of stream - pass empty array
        char[] empty = {};
        if (conn.read_cb != null)
        {
            conn.read_cb(conn, empty, conn.read_user_data);
        }
    }
    else if (nread < 0)
    {
        // Error - pass empty array (user should check connection state)
        io::printfn("Read error: %s", (ZString)uv::strerror((int)nread));
        char[] empty = {};
        if (conn.read_cb != null)
        {
            conn.read_cb(conn, empty, conn.read_user_data);
        }
    }

    // Free the buffer if it was allocated
    if (buf.base != null)
    {
        free(buf.base);
    }
}

<*
 Start reading from the connection.
 Data will be delivered via the read callback.

 @param alloc_cb: "Callback to allocate read buffers (can be null for default)"
 @param read_cb: "Callback when data arrives"
 @param user_data: "User context passed to callbacks"
*>
fn void? TcpConnection.start_read(&self, AllocCallback alloc_cb,
                                   ReadCallback read_cb, void* user_data = null) @public
{
    // Store callbacks in connection structure
    self.alloc_cb = alloc_cb;
    self.read_cb = read_cb;
    self.read_user_data = user_data;

    int result = uv::read_start((uv::Stream*)self.handle,
                                &on_alloc_internal, &on_read_internal);
    uv::@uv_check(result, "Failed to start reading", TCP_READ_FAILED)!;
}

<*
 Stop reading from the connection.
*>
fn void? TcpConnection.stop_read(&self) @public
{
    int result = uv::read_stop((uv::Stream*)self.handle);
    uv::@uv_check(result, "Failed to stop reading", TCP_READ_FAILED)!;
}

<*
 Internal write callback for libuv.
 Calls user's WriteCallback.
*>
fn void on_write_internal(uv::Write* req, int status)
{
    WriteContext* ctx = uv::req_get(WriteContext, req);

    if (ctx.cb != null)
    {
        ctx.cb(ctx.conn, status, ctx.user_data);
    }

    // Free the write context, buffers, and request
    if (ctx.bufs != null)
    {
        free(ctx.bufs.base);  // Free the copied data
        free(ctx.bufs);
    }
    free(ctx);
    free(req);
}

<*
 Write data to the connection asynchronously.

 @param data: "Data to write"
 @param callback: "Called when write completes"
 @param user_data: "User context passed to callback"
*>
fn void? TcpConnection.write(&self, char[] data, WriteCallback callback,
                             void* user_data = null) @public
{
    // Allocate write request and context (freed in callback)
    uv::Write* req = uv::alloc_req(uv::Write);
    WriteContext* ctx = mem::new(WriteContext);
    ctx.conn = self;
    ctx.cb = callback;
    ctx.user_data = user_data;

    // Create buffer (copy data so it stays valid until write completes)
    ctx.bufs = mem::new(uv::Buf);
    char* data_copy = mem::new_array(char, data.len);
    mem::copy(data_copy, data.ptr, data.len);
    ctx.bufs.base = data_copy;
    ctx.bufs.len = data.len;

    // Store context in request's data field
    uv::req_set(req, ctx);

    int result = uv::write(req, (uv::Stream*)self.handle,
                          ctx.bufs, 1, &on_write_internal);
    if (result != 0)
    {
        free(ctx.bufs.base);
        free(ctx.bufs);
        free(ctx);
        free(req);
        io::printfn("Failed to write: %s", (ZString)uv::strerror(result));
        return TCP_WRITE_FAILED?;
    }
}

<*
 Internal close callback.
 Frees the handle memory and the connection.
*>
fn void on_close_internal(uv::Handle* handle)
{
    // Get connection from handle and free both
    TcpConnection* conn = uv::handle_get(TcpConnection, handle);
    free(handle);
    if (conn != null)
    {
        free(conn);
    }
}

<*
 Close the TCP connection.
 This initiates async close - both handle and connection will be freed when close completes.
 DO NOT call free() or access the connection after calling close().
*>
fn void TcpConnection.close(&self) @public
{
    if (self.handle != null)
    {
        uv::close((uv::Handle*)self.handle, &on_close_internal);
        // Note: Both handle and connection will be freed by the callback
    }
}

<*
 Enable/disable TCP_NODELAY (disable/enable Nagle's algorithm).

 @param enable: "True to disable Nagle (send small packets immediately)"
*>
fn void? TcpConnection.set_nodelay(&self, bool enable) @public
{
    int result = uv::tcp_nodelay(self.handle, enable ? 1 : 0);
    uv::@uv_check(result, "Failed to set TCP_NODELAY", TCP_INIT_FAILED)!;
}

<*
 Enable/disable TCP keepalive.

 @param enable: "True to enable keepalive"
 @param delay: "Initial delay in seconds (only used if enable is true)"
*>
fn void? TcpConnection.set_keepalive(&self, bool enable, uint delay = 60) @public
{
    int result = uv::tcp_keepalive(self.handle, enable ? 1 : 0, delay);
    uv::@uv_check(result, "Failed to set TCP keepalive", TCP_INIT_FAILED)!;
}
