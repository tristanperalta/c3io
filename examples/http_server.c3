import std::io;
import async::event_loop;
import async::tcp;

fn char[] on_alloc(async::tcp::TcpConnection* conn, usz suggested_size, void* user_data)
{
  return mem::new_array(char, suggested_size);
}

fn void on_read(async::tcp::TcpConnection* client, char[] data, void* user_data)
{
  if (data.len == 0)
  {
    // EOF - client closed connection
    io::printfn("Client disconnected");
    client.close();
    return;
  }

  io::printfn("Received %d bytes: %s", data.len, (String)data);

  String response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!";
  client.write((char[])response.ptr[:response.len], &on_write)!!;
}

fn void on_write(async::tcp::TcpConnection* client, int status, void* user_data)
{
  if (status != 0)
  {
    io::eprintfn("Write failed");
  }
  client.close();
}

fn void on_connection(async::tcp::TcpConnection* server, async::tcp::TcpConnection* client, void* user_data)
{
  io::printfn("New client connected!");

  // Start reading from client
  client.start_read(&on_alloc, &on_read)!!;
}

fn int main()
{
  event_loop::EventLoop? loop_opt = event_loop::create();
  if (catch err = loop_opt)
  {
    io::eprintfn("Failed to create event loop");
    return 1;
  }
  event_loop::EventLoop loop = loop_opt;
  defer loop.free();

  async::tcp::TcpConnection*? server_opt = async::tcp::create(&loop);
  if (catch err = server_opt)
  {
    io::eprintfn("Failed to create server");
    return 1;
  }
  async::tcp::TcpConnection* server = server_opt;
  defer server.close();

  server.bind("0.0.0.0", 8080)!!;
  io::printfn("Server listening on http://0.0.0.0:8080");

  server.listen(128, &on_connection)!!;

  loop.run()!!;

  return 0;
}
