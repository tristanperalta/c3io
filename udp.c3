module async::udp;

import uv;
import std::io;
import async::event_loop;

<*
 Async UDP Socket Wrapper for libuv
 ===================================
 Provides async UDP socket operations using libuv.

 UDP is connectionless, so you can send/receive without "connecting".

 Usage:
   UdpSocket* socket = async::udp::create(loop);
   socket.bind("0.0.0.0", 6881);  // Optional - can send without binding
   socket.recv_start(&on_alloc, &on_recv, user_data);
   socket.send(addr, data, &on_send, user_data);
   // Later:
   socket.close();
*>

// Faults
faultdef UDP_INIT_FAILED;
faultdef UDP_BIND_FAILED;
faultdef UDP_SEND_FAILED;
faultdef UDP_RECV_FAILED;

// Callback types
alias SendCallback = fn void(UdpSocket* socket, int status, void* user_data);
alias RecvCallback = fn void(UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data);
alias AllocCallback = fn char[](UdpSocket* socket, usz suggested_size, void* user_data);

<*
 UDP socket state.
 Wraps a libuv UDP handle and provides async I/O.
*>
struct UdpSocket
{
    uv::Udp* handle;
    event_loop::EventLoop* loop;
    RecvCallback recv_cb;
    AllocCallback alloc_cb;
    void* recv_user_data;
}

<*
 Send request context.
 Stores the send request and callback.
*>
struct SendContext
{
    uv::UdpSend* req;
    UdpSocket* socket;
    SendCallback cb;
    void* user_data;
    uv::Buf* bufs;  // Keep buffer alive until send completes
}

// Internal libuv callback wrappers
fn void on_alloc_internal(uv::Handle* handle, usz suggested_size, uv::Buf* buf)
{
    UdpSocket* socket = uv::handle_get(UdpSocket, handle);

    if (socket.alloc_cb)
    {
        char[] user_buf = socket.alloc_cb(socket, suggested_size, socket.recv_user_data);
        buf.base = user_buf.ptr;
        buf.len = user_buf.len;
    }
    else
    {
        // Default allocation
        buf.base = mem::new_array(char, suggested_size);
        buf.len = suggested_size;
    }
}

fn void on_recv_internal(uv::Udp* handle, isz nread, uv::Buf* buf, uv::Sockaddr* addr, uint flags)
{
    UdpSocket* socket = uv::handle_get(UdpSocket, handle);

    if (socket.recv_cb)
    {
        char[] data = {};
        if (nread > 0)
        {
            data = ((char*)buf.base)[:nread];
        }

        socket.recv_cb(socket, data, addr, socket.recv_user_data);
    }

    // Free the buffer
    if (buf.base)
    {
        free(buf.base);
    }
}

fn void on_send_internal(uv::UdpSend* req, int status)
{
    SendContext* ctx = uv::req_get(SendContext, req);

    if (ctx.cb)
    {
        ctx.cb(ctx.socket, status, ctx.user_data);
    }

    // Clean up (including copied data buffer)
    if (ctx.bufs != null)
    {
        free(ctx.bufs.base);  // Free the copied data
        free(ctx.bufs);
    }
    free(ctx.req);
    free(ctx);
}

fn void on_close_internal(uv::Handle* handle)
{
    // Get socket from handle and free both
    UdpSocket* socket = uv::handle_get(UdpSocket, handle);
    free(handle);
    if (socket != null)
    {
        free(socket);
    }
}

<*
 Create a new UDP socket.

 @param loop : "Event loop to attach to"
*>
fn UdpSocket*? create(event_loop::EventLoop* loop) @public
{
    // Allocate UDP handle
    uv::Udp* handle = uv::alloc_handle(uv::Udp, uv::HandleType.UDP);

    // Initialize UDP handle
    int result = uv::udp_init(loop.loop, handle);
    if (result != 0)
    {
        free(handle);
        io::printfn("Failed to initialize UDP handle: %s", (ZString)uv::strerror(result));
        return UDP_INIT_FAILED?;
    }

    UdpSocket* socket = mem::new(UdpSocket);
    socket.handle = handle;
    socket.loop = loop;
    socket.recv_cb = null;
    socket.alloc_cb = null;
    socket.recv_user_data = null;

    // Store socket pointer in handle's data field
    uv::handle_set(handle, socket);

    return socket;
}

<*
 Bind the UDP socket to a local address.
 This is optional - you can send without binding.

 @param ip : "IP address to bind to (e.g., 0.0.0.0 for any)"
 @param port : "Port number to bind to"
*>
fn void UdpSocket.bind(&self, String ip, int port) @public
{
    uv::Sockaddr_in addr;
    ZString c_ip = (ZString)ip.ptr;

    int result = uv::ip4_addr(c_ip, port, &addr);
    if (result != 0)
    {
        io::printfn("Failed to parse IP address: %s", (ZString)uv::strerror(result));
        return;
    }

    result = uv::udp_bind(self.handle, (uv::Sockaddr*)&addr, uv::UV_UDP_REUSEADDR);
    if (result != 0)
    {
        io::printfn("Failed to bind UDP socket: %s", (ZString)uv::strerror(result));
    }
}

<*
 Send a UDP datagram to a specific address.

 @param ip : "Destination IP address"
 @param port : "Destination port"
 @param data : "Data to send"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void UdpSocket.send(&self, String ip, int port, char[] data,
                       SendCallback callback, void* user_data) @public
{
    SendContext* ctx = mem::new(SendContext);
    ctx.socket = self;
    ctx.cb = callback;
    ctx.user_data = user_data;

    // Allocate request
    ctx.req = uv::alloc_req(uv::UdpSend, uv::ReqType.UDP_SEND);
    uv::req_set(ctx.req, ctx);

    // Parse destination address
    uv::Sockaddr_in addr;
    ZString c_ip = (ZString)ip.ptr;

    int result = uv::ip4_addr(c_ip, port, &addr);
    if (result != 0)
    {
        io::printfn("Failed to parse destination address: %s", (ZString)uv::strerror(result));
        if (callback)
        {
            callback(self, result, user_data);
        }
        free(ctx.req);
        free(ctx);
        return;
    }

    // Prepare buffer (copy data so it stays valid until send completes)
    ctx.bufs = mem::new(uv::Buf);
    char* data_copy = mem::new_array(char, data.len);
    mem::copy(data_copy, data.ptr, data.len);
    ctx.bufs.base = data_copy;
    ctx.bufs.len = data.len;

    result = uv::udp_send(ctx.req, self.handle, ctx.bufs, 1,
                          (uv::Sockaddr*)&addr, &on_send_internal);

    if (result < 0)
    {
        // Immediate error
        io::printfn("Failed to send UDP datagram: %s", (ZString)uv::strerror(result));
        if (callback)
        {
            callback(self, result, user_data);
        }
        if (ctx.bufs != null)
        {
            free(ctx.bufs.base);  // Free the copied data
            free(ctx.bufs);
        }
        free(ctx.req);
        free(ctx);
    }
}

<*
 Send a UDP datagram to a sockaddr.
 Useful when you have a sockaddr from a previous recv.

 @param addr : "Destination address"
 @param data : "Data to send"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void UdpSocket.send_to(&self, uv::Sockaddr* addr, char[] data,
                          SendCallback callback, void* user_data) @public
{
    SendContext* ctx = mem::new(SendContext);
    ctx.socket = self;
    ctx.cb = callback;
    ctx.user_data = user_data;

    // Allocate request
    ctx.req = uv::alloc_req(uv::UdpSend, uv::ReqType.UDP_SEND);
    uv::req_set(ctx.req, ctx);

    // Prepare buffer (copy data so it stays valid until send completes)
    ctx.bufs = mem::new(uv::Buf);
    char* data_copy = mem::new_array(char, data.len);
    mem::copy(data_copy, data.ptr, data.len);
    ctx.bufs.base = data_copy;
    ctx.bufs.len = data.len;

    int result = uv::udp_send(ctx.req, self.handle, ctx.bufs, 1,
                              addr, &on_send_internal);

    if (result < 0)
    {
        // Immediate error
        io::printfn("Failed to send UDP datagram: %s", (ZString)uv::strerror(result));
        if (callback)
        {
            callback(self, result, user_data);
        }
        if (ctx.bufs != null)
        {
            free(ctx.bufs.base);  // Free the copied data
            free(ctx.bufs);
        }
        free(ctx.req);
        free(ctx);
    }
}

<*
 Start receiving UDP datagrams.

 @param alloc_cb : "Allocation callback (optional, can be null)"
 @param recv_cb : "Receive callback"
 @param user_data : "User data passed to callbacks"
*>
fn void UdpSocket.recv_start(&self, AllocCallback alloc_cb, RecvCallback recv_cb,
                             void* user_data) @public
{
    self.alloc_cb = alloc_cb;
    self.recv_cb = recv_cb;
    self.recv_user_data = user_data;

    int result = uv::udp_recv_start(self.handle, &on_alloc_internal, &on_recv_internal);
    if (result != 0)
    {
        io::printfn("Failed to start receiving UDP datagrams: %s", (ZString)uv::strerror(result));
    }
}

<*
 Stop receiving UDP datagrams.
*>
fn void UdpSocket.recv_stop(&self) @public
{
    uv::udp_recv_stop(self.handle);
}

<*
 Close the UDP socket and free resources.
 Note: This is async - the socket and handle will be freed when the close completes.
*>
fn void UdpSocket.close(&self) @public
{
    // Stop receiving first
    uv::udp_recv_stop(self.handle);

    // Close handle (async operation that will free both handle and socket via callback)
    uv::close((uv::Handle*)self.handle, &on_close_internal);
    // Note: Both handle and socket will be freed by the callback
}
