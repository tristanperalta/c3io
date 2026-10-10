module c3io::udp;

import c3io;
import c3io::uv;
import c3io::event_loop;
import c3io::net;

<*
 Async UDP sockets
 =================
 UDP is connectionless: a socket can send to any address, and receives
 datagrams from anyone once it is bound.

 Usage:
   UdpSocket* socket = udp::create(loop)!;
   socket.bind(net::addr("0.0.0.0", 7777)!)!;  // "::" binds IPv6 and IPv4
   socket.recv_start(&on_recv, user_data)!;

   SocketAddr peer = net::addr("192.168.1.20", 7777)!;
   socket.try_send(&peer, packet)!;            // no allocation, no callback
   socket.send(&peer, packet, &on_sent)!;      // queued if the kernel is busy

   socket.close();

 Receiving: without an allocate callback, the socket receives into one buffer
 of RECV_BUFFER_SIZE bytes that it reuses, so receiving allocates nothing.
 The `data` slice passed to the receive callback is only valid until the
 callback returns. With an allocate callback, the buffers are the caller's and
 c3io never frees them.
*>

excuse
{
    UDP_INIT_FAILED,
    UDP_BIND_FAILED,
    UDP_CONNECT_FAILED,
    UDP_SEND_FAILED,
    UDP_WOULD_BLOCK,
    UDP_RECV_FAILED,
    UDP_OPTION_FAILED,
}

<*
 Called when a queued send completes. status is 0 on success, UV_ECANCELED if
 the socket was closed first, or another negative libuv error.
*>
alias SendCallback = fn void(UdpSocket* socket, int status, void* user_data);

<*
 Called for each received datagram (status 0) or receive error (status < 0).
 `from` is the sender, null on error. `truncated` means the datagram was
 larger than the buffer. A zero-length datagram arrives as status 0 with empty
 data. `data.ptr` is the receive buffer even when `data` is empty.
*>
alias RecvCallback = fn void(UdpSocket* socket, int status, char[] data, SocketAddr* from,
                             bool truncated, void* user_data);

<*
 Returns a buffer for the next datagram. The buffer belongs to the caller; it
 may be reused once the receive callback for it has returned.
*>
alias AllocCallback = fn char[](UdpSocket* socket, usz suggested_size, void* user_data);

const usz RECV_BUFFER_SIZE = 64 * 1024;

// Sends of up to SEND_POOL_CAPACITY bytes reuse pooled contexts, which covers
// datagrams that fit an Ethernet MTU.
const usz SEND_POOL_CAPACITY = 1500;
const int SEND_POOL_MAX = 64;

struct UdpSocket
{
    event_loop::HandleOwner owner;
    Allocator allocator;
    uv::Udp* handle;
    event_loop::EventLoop* loop;
    RecvCallback recv_cb;
    AllocCallback alloc_cb;
    void* recv_user_data;
    char[] recv_buffer;  // Reused for every receive when alloc_cb is null
    RequestPool sends;
}

fn void on_alloc_internal(uv::Handle* handle, usz suggested_size, uv::Buf* buf) @private
{
    UdpSocket* socket = uv::handle_get(UdpSocket, handle);
    char[] target;
    if (socket.alloc_cb)
    {
        target = socket.alloc_cb(socket, suggested_size, socket.recv_user_data);
    }
    else
    {
        if (!socket.recv_buffer.ptr)
        {
            socket.recv_buffer = alloc::new_array(socket.allocator, char, (sz)RECV_BUFFER_SIZE);
        }
        target = socket.recv_buffer;
    }
    *buf = c3io::make_buf(target.ptr, target.len);
}

fn void on_recv_internal(uv::Udp* handle, sz nread, uv::Buf* buf, uv::Sockaddr* addr, uint flags) @private
{
    // libuv's "nothing more to read for now": no datagram, no error.
    if (nread == 0 && addr == null) return;

    UdpSocket* socket = uv::handle_get(UdpSocket, handle);
    if (!socket.recv_cb) return;

    char* base = (char*)buf.base;
    if (nread < 0)
    {
        socket.recv_cb(socket, (int)nread, base[:0], null, false, socket.recv_user_data);
        return;
    }
    SocketAddr from = net::from_sockaddr(addr);
    bool truncated = (flags & uv::UV_UDP_PARTIAL) != 0;
    socket.recv_cb(socket, 0, base[:nread], &from, truncated, socket.recv_user_data);
}

fn void on_send_internal(uv::UdpSend* req, int status) @private
{
    PooledRequest* r = uv::req_get(PooledRequest, req);
    UdpSocket* socket = r.owner;
    SendCallback callback = (SendCallback)r.callback;
    if (callback) callback(socket, status, r.user_data);
    socket.sends.release(r);
}

fn void on_close_internal(uv::Handle* handle) @private
{
    UdpSocket* socket = uv::handle_get(UdpSocket, handle);
    Allocator allocator = socket.allocator;
    socket.sends.free();
    if (socket.recv_buffer.ptr) alloc::free(allocator, socket.recv_buffer.ptr);
    alloc::free(allocator, handle);
    alloc::free(allocator, socket);
}

<*
 Create a new UDP socket.

 @param loop : "Event loop to attach to"
 @param allocator : "Allocator for the socket and its buffers (default: the loop's)"
*>
fn UdpSocket*? create(event_loop::EventLoop* loop, Allocator allocator = null)
{
    allocator = loop.allocator_or(allocator);
    uv::Udp* handle = c3io::alloc_handle(allocator, uv::Udp, uv::HandleType.UDP);

    int result = uv::udp_init(loop.loop, handle);
    if (result != 0)
    {
        alloc::free(allocator, handle);
        c3io::set_last_status(result);
        return UDP_INIT_FAILED~;
    }

    UdpSocket* socket = alloc::new(allocator, UdpSocket);
    socket.owner.init(&on_close_internal);
    socket.allocator = allocator;
    socket.handle = handle;
    socket.loop = loop;
    socket.sends.init(allocator, uv::ReqType.UDP_SEND, SEND_POOL_CAPACITY, SEND_POOL_MAX);
    uv::handle_set(handle, socket);
    return socket;
}

<*
 Bind the socket to a local address. Binding "::" also accepts IPv4 traffic
 unless ipv6_only is set (on systems that support dual-stack sockets).

 @param addr : "Local address; port 0 lets the system choose"
 @param reuse_addr : "Allow other sockets to bind the same address"
 @param ipv6_only : "For an IPv6 address, don't accept IPv4 traffic"
*>
fn void? UdpSocket.bind(&self, SocketAddr addr, bool reuse_addr = true, bool ipv6_only = false)
{
    uint flags = reuse_addr ? uv::UV_UDP_REUSEADDR : 0;
    if (ipv6_only) flags |= uv::UV_UDP_IPV6ONLY;
    c3io::@check(uv::udp_bind(self.handle, addr.sockaddr(), flags), UDP_BIND_FAILED)!;
}

<*
 Associate the socket with one remote address. Afterwards it only exchanges
 datagrams with that peer, and send/try_send take a null address.
*>
fn void? UdpSocket.connect(&self, SocketAddr addr)
{
    c3io::@check(uv::udp_connect(self.handle, addr.sockaddr()), UDP_CONNECT_FAILED)!;
}

<*
 Remove the association made by connect().
*>
fn void? UdpSocket.disconnect(&self)
{
    c3io::@check(uv::udp_connect(self.handle, null), UDP_CONNECT_FAILED)!;
}

<*
 Send a datagram immediately, without allocating or queuing. Fails with
 UDP_WOULD_BLOCK if the kernel can't take it right now; the caller can drop
 the packet or fall back to send().

 @param to : "Destination, or null on a connected socket"
 @param data : "Datagram contents"
 @return "Number of bytes sent"
*>
fn sz? UdpSocket.try_send(&self, SocketAddr* to, char[] data)
{
    uv::Buf buf = c3io::make_buf(data.ptr, data.len);
    int result = uv::udp_try_send(self.handle, &buf, 1, to ? to.sockaddr() : null);
    if (result >= 0) return result;
    c3io::set_last_status(result);
    if (result == uv::UV_EAGAIN) return UDP_WOULD_BLOCK~;
    return UDP_SEND_FAILED~;
}

<*
 Queue a datagram. The data is copied, so the caller can reuse it at once.
 Sends of up to SEND_POOL_CAPACITY bytes reuse pooled memory, so steady
 traffic doesn't allocate. If the send can't be queued, it fails with a fault
 and the callback isn't called.

 @param to : "Destination, or null on a connected socket"
 @param data : "Datagram contents"
 @param callback : "Called when the send completes (optional)"
 @param user_data : "Passed to the callback"
*>
fn void? UdpSocket.send(&self, SocketAddr* to, char[] data, SendCallback callback = null,
                        void* user_data = null)
{
    PooledRequest* r = self.sends.acquire(data);
    r.owner = self;
    r.callback = (void*)callback;
    r.user_data = user_data;

    int result = uv::udp_send(r.req, self.handle, &r.buf, 1, to ? to.sockaddr() : null,
                              &on_send_internal);
    if (result < 0)
    {
        self.sends.release(r);
        c3io::set_last_status(result);
        return UDP_SEND_FAILED~;
    }
}

<*
 Start receiving datagrams.

 @param recv_cb : "Called for each datagram or receive error"
 @param user_data : "Passed to the callbacks"
 @param alloc_cb : "Supplies receive buffers (optional; default: one reused internal buffer)"
*>
fn void? UdpSocket.recv_start(&self, RecvCallback recv_cb, void* user_data = null,
                              AllocCallback alloc_cb = null)
{
    self.recv_cb = recv_cb;
    self.alloc_cb = alloc_cb;
    self.recv_user_data = user_data;
    c3io::@check(uv::udp_recv_start(self.handle, &on_alloc_internal, &on_recv_internal),
                 UDP_RECV_FAILED)!;
}

<*
 Stop receiving datagrams.
*>
fn void? UdpSocket.recv_stop(&self)
{
    c3io::@check(uv::udp_recv_stop(self.handle), UDP_RECV_FAILED)!;
}

<*
 Allow or forbid sending to broadcast addresses, e.g. for LAN discovery.
*>
fn void? UdpSocket.set_broadcast(&self, bool enable)
{
    c3io::@check(uv::udp_set_broadcast(self.handle, enable ? 1 : 0), UDP_OPTION_FAILED)!;
}

<*
 Set the kernel send buffer size in bytes. The system may round or double it.
*>
fn void? UdpSocket.set_send_buffer_size(&self, int bytes)
{
    c3io::@check(uv::send_buffer_size(self.handle, &bytes), UDP_OPTION_FAILED)!;
}

<*
 Set the kernel receive buffer size in bytes. The system may round or double it.
*>
fn void? UdpSocket.set_recv_buffer_size(&self, int bytes)
{
    c3io::@check(uv::recv_buffer_size(self.handle, &bytes), UDP_OPTION_FAILED)!;
}

<*
 The kernel send buffer size in bytes.
*>
fn int? UdpSocket.send_buffer_size(&self)
{
    int bytes = 0;
    c3io::@check(uv::send_buffer_size(self.handle, &bytes), UDP_OPTION_FAILED)!;
    return bytes;
}

<*
 The kernel receive buffer size in bytes.
*>
fn int? UdpSocket.recv_buffer_size(&self)
{
    int bytes = 0;
    c3io::@check(uv::recv_buffer_size(self.handle, &bytes), UDP_OPTION_FAILED)!;
    return bytes;
}

<*
 The local address the socket is bound to.
*>
fn SocketAddr? UdpSocket.local_addr(&self)
{
    SocketAddr addr;
    int len = SocketAddr::size;
    c3io::@check(uv::udp_getsockname(self.handle, addr.sockaddr(), &len), UDP_OPTION_FAILED)!;
    return addr;
}

<*
 The remote address of a connected socket.
*>
fn SocketAddr? UdpSocket.peer_addr(&self)
{
    SocketAddr addr;
    int len = SocketAddr::size;
    c3io::@check(uv::udp_getpeername(self.handle, addr.sockaddr(), &len), UDP_OPTION_FAILED)!;
    return addr;
}

<*
 Close the socket. Queued sends complete with UV_ECANCELED, then the socket
 is freed. Don't use the socket after calling this.
*>
fn void UdpSocket.close(&self)
{
    uv::udp_recv_stop(self.handle);
    uv::close((uv::Handle*)self.handle, &on_close_internal);
}
