module c3io::tcp_test;

import c3io;
import c3io::event_loop;
import c3io::tcp;
import c3io::net;
import c3io::uv;

macro void @pump(EventLoop* loop, #done, int max_iterations = 500)
{
    for (int i = 0; i < max_iterations && !#done; i++) loop.run_once();
}

macro void @drain(EventLoop* loop)
{
    while (loop.is_alive()) loop.run_once();
}

<*
 Server side of a test: accepts one client and optionally reads from it.
*>
struct Server
{
    TcpConnection* listener;
    TcpConnection* client;
    int accept_status;
    bool accepted;
    bool read_client;      // Start reading on the accepted client
    char[64] received;
    usz received_len;
    String reply;          // Written back when data arrives, if set
}

fn void on_server_read(TcpConnection* conn, int status, char[] data, void* user_data)
{
    Server* server = user_data;
    if (status != 0) return;
    usz n = data.len;
    if (server.received_len + n > server.received.len) n = server.received.len - server.received_len;
    server.received[server.received_len:n] = data[:n];
    server.received_len += n;
    if (server.reply.len) conn.try_write(server.reply)!!;
}

fn void on_accept(TcpConnection* listener, int status, TcpConnection* client, void* user_data)
{
    Server* server = user_data;
    server.accepted = true;
    server.accept_status = status;
    server.client = client;
    if (client && server.read_client) client.read_start(&on_server_read, server)!!;
}

fn SocketAddr start_server(EventLoop* loop, Server* server, String ip = "127.0.0.1")
{
    server.listener = tcp::create(loop)!!;
    server.listener.bind(net::addr(ip, 0)!!)!!;
    server.listener.listen(16, &on_accept, server)!!;
    return server.listener.local_addr()!!;
}

fn void Server.close(&self)
{
    if (self.client) self.client.close();
    self.listener.close();
}

<*
 Client side of a test.
*>
struct Client
{
    TcpConnection* conn;
    bool connected;
    int connect_status;
    int read_status;       // Status of the last read callback
    int reads;
    char[64] received;
    usz received_len;
    void* last_ptr;
    bool eof;
}

fn void on_client_read(TcpConnection* conn, int status, char[] data, void* user_data)
{
    Client* client = user_data;
    client.reads++;
    client.read_status = status;
    client.last_ptr = data.ptr;
    if (status == uv::UV_EOF) client.eof = true;
    if (status == 0)
    {
        usz n = data.len;
        if (client.received_len + n > client.received.len) n = client.received.len - client.received_len;
        client.received[client.received_len:n] = data[:n];
        client.received_len += n;
    }
}

fn void on_connect(TcpConnection* conn, int status, void* user_data)
{
    Client* client = user_data;
    client.connected = true;
    client.connect_status = status;
    if (status == 0) conn.read_start(&on_client_read, client)!!;
}

fn void test_tcp_create_and_close() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;
    TcpConnection* conn = tcp::create(&loop)!!;
    conn.close();
    @drain(&loop);
}

fn void test_tcp_connect_and_accept() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    Server server;
    SocketAddr server_addr = start_server(&loop, &server);
    Client client;
    client.conn = tcp::connect(&loop, server_addr, &on_connect, &client)!!;

    @pump(&loop, client.connected && server.accepted);
    assert(client.connect_status == 0);
    assert(server.accept_status == 0);
    assert(server.client != null);
    assert(client.conn.peer_addr()!! == server_addr);
    assert(server.client.peer_addr()!! == client.conn.local_addr()!!);

    client.conn.close();
    server.close();
    @drain(&loop);
}

fn void test_tcp_connect_refused_closes_connection() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    // A bound but not listening socket reserves a port nobody accepts on.
    TcpConnection* placeholder = tcp::create(&loop)!!;
    placeholder.bind(net::addr("127.0.0.1", 0)!!)!!;
    SocketAddr addr = placeholder.local_addr()!!;

    Client client;
    tcp::connect(&loop, addr, &on_connect, &client)!!;
    @pump(&loop, client.connected);
    assert(client.connect_status < 0, "Connect should fail");

    placeholder.close();
    @drain(&loop);  // The failed connection was closed for us.
}

fn void on_unused_connect(TcpConnection* conn, int status, void* user_data)
{
}

fn void test_tcp_connect_that_cannot_start_leaves_loop_closable() @test
{
    EventLoop loop = event_loop::create()!!;

    SocketAddr no_family;  // Neither IPv4 nor IPv6
    if (try tcp::connect(&loop, no_family, &on_unused_connect))
    {
        assert(false, "Connecting to an address without a family should fail");
    }
    @drain(&loop);

    if (catch err = loop.free()) assert(false, "Loop should close after the failed connect");
}

fn void test_tcp_echo_then_eof() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    Server server = { .read_client = true, .reply = "pong" };
    SocketAddr server_addr = start_server(&loop, &server);
    Client client;
    client.conn = tcp::connect(&loop, server_addr, &on_connect, &client)!!;

    @pump(&loop, client.connected && server.client != null);
    client.conn.write("ping")!!;
    @pump(&loop, client.received_len == 4);
    assert((String)server.received[:server.received_len] == "ping");
    assert((String)client.received[:client.received_len] == "pong");

    server.client.close();
    server.client = null;
    @pump(&loop, client.eof);
    assert(client.eof, "Client should see end of stream as UV_EOF");

    client.conn.close();
    server.close();
    @drain(&loop);
}

fn void test_tcp_reset_is_reported_as_error() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    // The server never reads. Closing a socket with unread data makes the
    // kernel reset the connection instead of ending it cleanly.
    Server server;
    SocketAddr server_addr = start_server(&loop, &server);
    Client client;
    client.conn = tcp::connect(&loop, server_addr, &on_connect, &client)!!;
    @pump(&loop, client.connected && server.client != null);

    int written;
    client.conn.write("unread", &on_written, &written)!!;
    @pump(&loop, written == 1);
    server.client.close();
    server.client = null;

    @pump(&loop, client.read_status < 0);
    assert(client.read_status < 0, "Client should get a negative read status");
    assert(!client.eof, "A reset is an error, not end of stream");
    if (env::LINUX) assert(client.read_status == uv::UV_ECONNRESET);

    client.conn.close();
    server.close();
    @drain(&loop);
}

char[8] static_buffer;

fn char[] alloc_static(TcpConnection* conn, usz suggested_size, void* user_data)
{
    return &static_buffer;
}

fn void on_connect_static(TcpConnection* conn, int status, void* user_data)
{
    Client* client = user_data;
    client.connected = true;
    client.connect_status = status;
    conn.read_start(&on_client_read, client, &alloc_static)!!;
}

fn void test_tcp_caller_buffer_is_not_freed() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    Server server = { .read_client = true, .reply = "0123456789abcdef" };
    SocketAddr server_addr = start_server(&loop, &server);
    Client client;
    client.conn = tcp::connect(&loop, server_addr, &on_connect_static, &client)!!;
    @pump(&loop, client.connected && server.client != null);

    client.conn.write("x")!!;
    @pump(&loop, client.received_len == 16);
    assert((String)client.received[:16] == "0123456789abcdef");
    assert(client.last_ptr == &static_buffer, "Data should arrive in the caller's buffer");

    client.conn.close();
    server.close();
    @drain(&loop);
}

fn void on_written(TcpConnection* conn, int status, void* user_data)
{
    int* written = user_data;
    if (status == 0) (*written)++;
}

fn void test_tcp_writes_reuse_pooled_memory() @test
{
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    Server server = { .read_client = true };
    SocketAddr server_addr = start_server(&loop, &server);
    Client client;
    client.conn = tcp::connect(&loop, server_addr, &on_connect, &client, &tracker)!!;
    @pump(&loop, client.connected && server.client != null);
    sz baseline = tracker.total_allocation_count();

    int written;
    for (int batch = 0; batch < 100; batch++)
    {
        for (int i = 0; i < 10; i++) client.conn.write("tick", &on_written, &written)!!;
        @pump(&loop, written == (batch + 1) * 10);
    }
    assert(written == 1000);
    assert(tracker.total_allocation_count() - baseline <= tcp::WRITE_POOL_MAX,
           "Writes should reuse pooled requests");

    client.conn.close();
    server.close();
    @drain(&loop);
    assert(tracker.allocation_count() == 0);
}

fn void test_tcp_options() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;
    TcpConnection* conn = tcp::create(&loop)!!;
    conn.set_nodelay(true)!!;
    conn.set_keepalive(true, 60)!!;
    conn.close();
    @drain(&loop);
}

fn void test_tcp_ipv6_connect() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    TcpConnection* probe = tcp::create(&loop)!!;
    bool has_ipv6 = @ok(probe.bind(net::addr("::1", 0)!!));
    probe.close();
    @drain(&loop);
    if (!has_ipv6) return;

    Server server;
    SocketAddr server_addr = start_server(&loop, &server, "::1");
    assert(server_addr.is_ipv6());
    Client client;
    client.conn = tcp::connect(&loop, server_addr, &on_connect, &client)!!;
    @pump(&loop, client.connected && server.accepted);
    assert(client.connect_status == 0);

    client.conn.close();
    server.close();
    @drain(&loop);
}
