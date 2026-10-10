// A minimal HTTP server: answers every request with "Hello, World!" and
// closes the connection. Run it and open http://localhost:8080.
import std::io;
import c3io;
import c3io::event_loop;
import c3io::tcp;
import c3io::net;
import c3io::uv;

const String RESPONSE = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nConnection: close\r\n\r\nHello, World!";

fn void on_write(TcpConnection* client, int status, void* user_data)
{
    if (status != 0) io::eprintfn("Write failed: %s", c3io::error_message(status));
    client.close();
}

fn void on_read(TcpConnection* client, int status, char[] data, void* user_data)
{
    if (status == uv::UV_EOF)
    {
        client.close();
        return;
    }
    if (status != 0)
    {
        io::eprintfn("Read failed: %s", c3io::error_message(status));
        client.close();
        return;
    }
    // A real server would parse the request; this one answers the first read.
    (void)client.read_stop();
    if (catch client.write(RESPONSE, &on_write)) client.close();
}

fn void on_accept(TcpConnection* server, int status, TcpConnection* client, void* user_data)
{
    if (status != 0)
    {
        io::eprintfn("Accept failed: %s", c3io::error_message(status));
        return;
    }
    if (try peer = client.peer_addr()) io::printfn("Connection from %s", peer);
    if (catch client.read_start(&on_read)) client.close();
}

fn int main()
{
    EventLoop loop = event_loop::create()!!;
    defer
    {
        while (!loop.shutdown()) {}
        loop.free()!!;
    }

    TcpConnection* server = tcp::create(&loop)!!;
    server.bind(net::addr("0.0.0.0", 8080)!!)!!;
    server.listen(128, &on_accept)!!;
    io::printfn("Listening on http://localhost:8080");

    loop.run()!!;
    return 0;
}
