module async::udp::test;

import async::udp;
import async::event_loop;
import uv;
import std::io;

// Test result tracking
struct TestContext
{
    bool success;
    bool completed;
    int send_count;
    int recv_count;
    event_loop::EventLoop* loop;
    async::udp::UdpSocket* sender;
    async::udp::UdpSocket* receiver;
    char[] received_data;
    uv::Sockaddr* sender_addr;
}

// ============================================================================
// Create/Close Tests
// ============================================================================

fn void test_create_close_socket() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    // Create UDP socket
    async::udp::UdpSocket*? socket_opt = async::udp::create(&loop);
    if (catch err = socket_opt)
    {
        assert(false, "Should create UDP socket");
        return;
    }
    async::udp::UdpSocket* socket = socket_opt;

    // Close socket
    socket.close();

    // Run loop until close completes
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Bind Tests
// ============================================================================

fn void test_bind_socket() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    async::udp::UdpSocket*? socket_opt = async::udp::create(&loop);
    if (catch err = socket_opt)
    {
        assert(false, "Should create UDP socket");
        return;
    }
    async::udp::UdpSocket* socket = socket_opt;

    // Bind to any address on a random port (0 = let OS choose)
    socket.bind("0.0.0.0", 0);

    // Close socket
    socket.close();

    // Run loop until close completes
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Send/Receive Tests
// ============================================================================

fn void on_recv_echo(async::udp::UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;

    if (data.len > 0)
    {
        ctx.recv_count++;

        // Copy received data for verification
        ctx.received_data = mem::new_array(char, data.len);
        for (usz i = 0; i < data.len; i++)
        {
            ctx.received_data[i] = data[i];
        }

        // Verify data
        String expected = "Hello UDP!";
        if (data.len == expected.len)
        {
            bool matches = true;
            for (usz i = 0; i < data.len; i++)
            {
                if (data[i] != expected[i])
                {
                    matches = false;
                    break;
                }
            }
            if (matches)
            {
                ctx.success = true;
                ctx.completed = true;
            }
        }
    }
}

fn char[] on_alloc_default(async::udp::UdpSocket* socket, usz suggested_size, void* user_data)
{
    return mem::new_array(char, suggested_size);
}

fn void on_send_complete(async::udp::UdpSocket* socket, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.send_count++;

    if (status < 0)
    {
        io::printfn("Send failed: %s", (ZString)uv::strerror(status));
        ctx.success = false;
        ctx.completed = true;
    }
}

fn void test_send_receive() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.send_count = 0;
    ctx.recv_count = 0;
    ctx.loop = &loop;
    ctx.received_data = {};

    // Create receiver socket
    async::udp::UdpSocket*? receiver_opt = async::udp::create(&loop);
    if (catch err = receiver_opt)
    {
        assert(false, "Should create receiver socket");
        return;
    }
    async::udp::UdpSocket* receiver = receiver_opt;
    ctx.receiver = receiver;

    // Bind receiver to localhost on port 9001
    receiver.bind("127.0.0.1", 9001);

    // Start receiving
    receiver.recv_start(&on_alloc_default, &on_recv_echo, &ctx);

    // Create sender socket
    async::udp::UdpSocket*? sender_opt = async::udp::create(&loop);
    if (catch err = sender_opt)
    {
        assert(false, "Should create sender socket");
        return;
    }
    async::udp::UdpSocket* sender = sender_opt;
    ctx.sender = sender;

    // Send datagram to receiver
    String test_data = "Hello UDP!";
    sender.send("127.0.0.1", 9001, (char[])test_data, &on_send_complete, &ctx);

    // Run event loop until we receive the datagram
    int max_iterations = 100;
    int iterations = 0;
    while (!ctx.completed && iterations < max_iterations)
    {
        loop.run_once();
        iterations++;
    }

    assert(ctx.success, "Should receive datagram");
    assert(ctx.send_count == 1, "Should send once");
    assert(ctx.recv_count == 1, "Should receive once");

    // Clean up
    if (ctx.received_data.len > 0)
    {
        free(ctx.received_data);
    }
    sender.close();
    receiver.close();

    // Run loop until close completes
    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Multiple Datagrams Test
// ============================================================================

struct MultiContext
{
    int messages_to_send;
    int sent;
    int received;
    bool completed;
    event_loop::EventLoop* loop;
}

fn void on_recv_multi(async::udp::UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data)
{
    MultiContext* ctx = (MultiContext*)user_data;

    if (data.len > 0)
    {
        ctx.received++;

        if (ctx.received >= ctx.messages_to_send)
        {
            ctx.completed = true;
        }
    }
}

fn void on_send_multi(async::udp::UdpSocket* socket, int status, void* user_data)
{
    MultiContext* ctx = (MultiContext*)user_data;

    if (status == 0)
    {
        ctx.sent++;
    }
}

fn void test_multiple_datagrams() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    MultiContext ctx;
    ctx.messages_to_send = 5;
    ctx.sent = 0;
    ctx.received = 0;
    ctx.completed = false;
    ctx.loop = &loop;

    // Create receiver
    async::udp::UdpSocket*? receiver_opt = async::udp::create(&loop);
    if (catch err = receiver_opt)
    {
        assert(false, "Should create receiver socket");
        return;
    }
    async::udp::UdpSocket* receiver = receiver_opt;

    receiver.bind("127.0.0.1", 9002);
    receiver.recv_start(&on_alloc_default, &on_recv_multi, &ctx);

    // Create sender
    async::udp::UdpSocket*? sender_opt = async::udp::create(&loop);
    if (catch err = sender_opt)
    {
        assert(false, "Should create sender socket");
        return;
    }
    async::udp::UdpSocket* sender = sender_opt;

    // Send multiple datagrams
    for (int i = 0; i < ctx.messages_to_send; i++)
    {
        String msg = "Message";
        sender.send("127.0.0.1", 9002, (char[])msg, &on_send_multi, &ctx);
    }

    // Run event loop until all messages received
    int max_iterations = 200;
    int iterations = 0;
    while (!ctx.completed && iterations < max_iterations)
    {
        loop.run_once();
        iterations++;
    }

    assert(ctx.sent == ctx.messages_to_send, "Should send all messages");
    assert(ctx.received == ctx.messages_to_send, "Should receive all messages");

    // Clean up
    sender.close();
    receiver.close();

    while (loop.is_alive())
    {
        loop.run_once();
    }
}

// ============================================================================
// Send To (with sockaddr) Test
// ============================================================================

struct SendToContext
{
    bool send_completed;
    bool recv_completed;
    uv::Sockaddr* sender_addr;
    event_loop::EventLoop* loop;
}

fn void on_recv_capture_addr(async::udp::UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data)
{
    SendToContext* ctx = (SendToContext*)user_data;

    if (data.len > 0 && !ctx.recv_completed)
    {
        ctx.recv_completed = true;

        // Save sender address for reply
        if (addr)
        {
            ctx.sender_addr = mem::new(uv::Sockaddr);
            *ctx.sender_addr = *addr;

            // Send reply back to sender
            String reply = "Reply";
            socket.send_to(ctx.sender_addr, (char[])reply, null, null);
        }
    }
}

fn void on_recv_reply(async::udp::UdpSocket* socket, char[] data, uv::Sockaddr* addr, void* user_data)
{
    SendToContext* ctx = (SendToContext*)user_data;

    if (data.len > 0)
    {
        // Verify we got the reply
        String expected = "Reply";
        if (data.len == expected.len)
        {
            bool matches = true;
            for (usz i = 0; i < data.len; i++)
            {
                if (data[i] != expected[i])
                {
                    matches = false;
                    break;
                }
            }
            if (matches)
            {
                ctx.send_completed = true;
            }
        }
    }
}

fn void test_send_to_addr() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    SendToContext ctx;
    ctx.send_completed = false;
    ctx.recv_completed = false;
    ctx.sender_addr = null;
    ctx.loop = &loop;

    // Create receiver (will reply to sender)
    async::udp::UdpSocket*? receiver_opt = async::udp::create(&loop);
    if (catch err = receiver_opt)
    {
        assert(false, "Should create receiver socket");
        return;
    }
    async::udp::UdpSocket* receiver = receiver_opt;

    receiver.bind("127.0.0.1", 9003);
    receiver.recv_start(&on_alloc_default, &on_recv_capture_addr, &ctx);

    // Create sender (will receive reply)
    async::udp::UdpSocket*? sender_opt = async::udp::create(&loop);
    if (catch err = sender_opt)
    {
        assert(false, "Should create sender socket");
        return;
    }
    async::udp::UdpSocket* sender = sender_opt;

    sender.bind("127.0.0.1", 9004);
    sender.recv_start(&on_alloc_default, &on_recv_reply, &ctx);

    // Send initial message
    String initial = "Hello";
    sender.send("127.0.0.1", 9003, (char[])initial, null, null);

    // Run event loop until reply received
    int max_iterations = 200;
    int iterations = 0;
    while (!ctx.send_completed && iterations < max_iterations)
    {
        loop.run_once();
        iterations++;
    }

    assert(ctx.recv_completed, "Should receive initial message");
    assert(ctx.send_completed, "Should receive reply");

    // Clean up
    if (ctx.sender_addr)
    {
        free(ctx.sender_addr);
    }
    sender.close();
    receiver.close();

    while (loop.is_alive())
    {
        loop.run_once();
    }
}
