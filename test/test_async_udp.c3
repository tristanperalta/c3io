module c3io::udp::test;

import c3io;
import c3io::udp;
import c3io::net;
import c3io::event_loop;
import c3io::uv;

// Receiver state shared by most tests.
struct Inbox
{
    int count;
    int last_status;
    char[64] last_data;
    usz last_len;
    bool truncated;
    SocketAddr from;
    void* last_ptr;
}

fn void on_recv(UdpSocket* socket, int status, char[] data, SocketAddr* from, bool truncated,
                void* user_data)
{
    Inbox* inbox = user_data;
    inbox.count++;
    inbox.last_status = status;
    inbox.truncated = truncated;
    inbox.last_ptr = data.ptr;
    inbox.last_len = data.len;
    if (data.len) inbox.last_data[:data.len] = data[..];
    if (from) inbox.from = *from;
}

<*
 Bind a socket to an ephemeral loopback port and return the address it got.
*>
fn SocketAddr bind_loopback(UdpSocket* socket, String ip = "127.0.0.1")
{
    socket.bind(net::addr(ip, 0)!!)!!;
    return socket.local_addr()!!;
}

macro void @pump(EventLoop* loop, #done, int max_iterations = 200)
{
    for (int i = 0; i < max_iterations && !#done; i++) loop.run_once();
}

macro void @drain(EventLoop* loop)
{
    while (loop.is_alive()) loop.run_once();
}

fn void test_create_close_socket() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;
    UdpSocket* socket = udp::create(&loop)!!;
    socket.close();
    @drain(&loop);
}

fn void test_bind_reports_local_address() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;
    UdpSocket* socket = udp::create(&loop)!!;
    SocketAddr local = bind_loopback(socket);
    assert(local.is_ipv4());
    assert(local.port() != 0, "System should assign a port");
    socket.close();
    @drain(&loop);
}

fn void on_sent(UdpSocket* socket, int status, void* user_data)
{
    int* sent = user_data;
    if (status == 0) (*sent)++;
}

fn void test_send_receive() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* receiver = udp::create(&loop)!!;
    SocketAddr receiver_addr = bind_loopback(receiver);
    Inbox inbox;
    receiver.recv_start(&on_recv, &inbox)!!;

    UdpSocket* sender = udp::create(&loop)!!;
    SocketAddr sender_addr = bind_loopback(sender);
    int sent;
    sender.send(&receiver_addr, "Hello UDP!", &on_sent, &sent)!!;

    @pump(&loop, inbox.count == 1 && sent == 1);
    assert(sent == 1, "Send callback should report success");
    assert(inbox.count == 1);
    assert(inbox.last_status == 0);
    assert((String)inbox.last_data[:inbox.last_len] == "Hello UDP!");
    assert(inbox.from == sender_addr, "Sender address should be reported");
    assert(!inbox.truncated);

    sender.close();
    receiver.close();
    @drain(&loop);
}

fn void test_multiple_datagrams() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* receiver = udp::create(&loop)!!;
    SocketAddr receiver_addr = bind_loopback(receiver);
    Inbox inbox;
    receiver.recv_start(&on_recv, &inbox)!!;

    UdpSocket* sender = udp::create(&loop)!!;
    int sent;
    for (int i = 0; i < 5; i++) sender.send(&receiver_addr, "Message", &on_sent, &sent)!!;

    @pump(&loop, inbox.count == 5 && sent == 5);
    assert(sent == 5);
    assert(inbox.count == 5);

    sender.close();
    receiver.close();
    @drain(&loop);
}

struct EchoState
{
    Inbox inbox;
    bool replied;
}

fn void on_recv_echo(UdpSocket* socket, int status, char[] data, SocketAddr* from, bool truncated,
                     void* user_data)
{
    EchoState* state = user_data;
    if (status == 0 && !state.replied)
    {
        state.replied = true;
        socket.send(from, "Reply")!!;
    }
}

fn void test_reply_to_sender_address() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* server = udp::create(&loop)!!;
    SocketAddr server_addr = bind_loopback(server);
    EchoState state;
    server.recv_start(&on_recv_echo, &state)!!;

    UdpSocket* client = udp::create(&loop)!!;
    bind_loopback(client);
    Inbox replies;
    client.recv_start(&on_recv, &replies)!!;
    client.send(&server_addr, "Hello")!!;

    @pump(&loop, replies.count == 1);
    assert(state.replied);
    assert((String)replies.last_data[:replies.last_len] == "Reply");
    assert(replies.from == server_addr);

    client.close();
    server.close();
    @drain(&loop);
}

fn void test_try_send() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* receiver = udp::create(&loop)!!;
    SocketAddr receiver_addr = bind_loopback(receiver);
    Inbox inbox;
    receiver.recv_start(&on_recv, &inbox)!!;

    UdpSocket* sender = udp::create(&loop)!!;
    sz sent = sender.try_send(&receiver_addr, "fast path")!!;
    assert(sent == 9);

    @pump(&loop, inbox.count == 1);
    assert((String)inbox.last_data[:inbox.last_len] == "fast path");

    sender.close();
    receiver.close();
    @drain(&loop);
}

fn void test_connected_socket() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* server = udp::create(&loop)!!;
    SocketAddr server_addr = bind_loopback(server);
    Inbox inbox;
    server.recv_start(&on_recv, &inbox)!!;

    UdpSocket* client = udp::create(&loop)!!;
    client.connect(server_addr)!!;
    assert(client.peer_addr()!! == server_addr);
    client.try_send(null, "connected")!!;
    client.send(null, "queued")!!;

    @pump(&loop, inbox.count == 2);
    assert(inbox.count == 2);

    client.disconnect()!!;
    if (try client.peer_addr()) assert(false, "Disconnected socket has no peer");

    client.close();
    server.close();
    @drain(&loop);
}

fn void test_empty_datagram() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* receiver = udp::create(&loop)!!;
    SocketAddr receiver_addr = bind_loopback(receiver);
    Inbox inbox;
    inbox.last_status = -1;
    receiver.recv_start(&on_recv, &inbox)!!;

    UdpSocket* sender = udp::create(&loop)!!;
    sender.send(&receiver_addr, "")!!;

    @pump(&loop, inbox.count == 1);
    assert(inbox.count == 1, "An empty datagram is still delivered");
    assert(inbox.last_status == 0);
    assert(inbox.last_len == 0);

    sender.close();
    receiver.close();
    @drain(&loop);
}

// A buffer the test owns. If c3io freed it, ASan would report an invalid free.
char[8] static_buffer;

fn char[] alloc_static(UdpSocket* socket, usz suggested_size, void* user_data)
{
    return &static_buffer;
}

fn void test_caller_buffer_is_not_freed_and_truncation_is_reported() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* receiver = udp::create(&loop)!!;
    SocketAddr receiver_addr = bind_loopback(receiver);
    Inbox inbox;
    receiver.recv_start(&on_recv, &inbox, &alloc_static)!!;

    UdpSocket* sender = udp::create(&loop)!!;
    sender.send(&receiver_addr, "1234")!!;
    sender.send(&receiver_addr, "longer than eight bytes")!!;

    @pump(&loop, inbox.count == 2);
    assert(inbox.count == 2);
    assert(inbox.last_ptr == &static_buffer, "Data should be in the caller's buffer");
    assert(inbox.truncated, "Oversized datagram should be reported as truncated");
    assert(inbox.last_len == 8);

    sender.close();
    receiver.close();
    @drain(&loop);
}

fn void test_sends_reuse_pooled_memory() @test
{
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* receiver = udp::create(&loop)!!;
    SocketAddr receiver_addr = bind_loopback(receiver);
    Inbox inbox;
    receiver.recv_start(&on_recv, &inbox)!!;

    UdpSocket* sender = udp::create(&loop, &tracker)!!;
    int sent;
    for (int batch = 0; batch < 100; batch++)
    {
        for (int i = 0; i < 10; i++) sender.send(&receiver_addr, "tick", &on_sent, &sent)!!;
        @pump(&loop, sent == (batch + 1) * 10);
    }
    assert(sent == 1000);
    assert(tracker.total_allocation_count() <= 2 + udp::SEND_POOL_MAX,
           "Sends should reuse pooled contexts, got %d allocations", tracker.total_allocation_count());

    sender.close();
    receiver.close();
    @drain(&loop);
    assert(tracker.allocation_count() == 0, "Pool should be freed on close");
}

fn void test_socket_options() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* socket = udp::create(&loop)!!;
    bind_loopback(socket);
    socket.set_broadcast(true)!!;
    socket.set_broadcast(false)!!;
    socket.set_send_buffer_size(64 * 1024)!!;
    socket.set_recv_buffer_size(64 * 1024)!!;
    assert(socket.send_buffer_size()!! >= 64 * 1024);
    assert(socket.recv_buffer_size()!! >= 64 * 1024);

    socket.close();
    @drain(&loop);
}

fn void test_ipv6_send_receive() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* receiver = udp::create(&loop)!!;
    if (catch receiver.bind(net::addr("::1", 0)!!))
    {
        // No IPv6 loopback on this machine.
        receiver.close();
        @drain(&loop);
        return;
    }
    SocketAddr receiver_addr = receiver.local_addr()!!;
    assert(receiver_addr.is_ipv6());
    Inbox inbox;
    receiver.recv_start(&on_recv, &inbox)!!;

    UdpSocket* sender = udp::create(&loop)!!;
    SocketAddr sender_addr = bind_loopback(sender, "::1");
    sender.try_send(&receiver_addr, "over v6")!!;

    @pump(&loop, inbox.count == 1);
    assert((String)inbox.last_data[:inbox.last_len] == "over v6");
    assert(inbox.from == sender_addr);

    sender.close();
    receiver.close();
    @drain(&loop);
}
