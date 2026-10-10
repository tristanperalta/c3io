module c3io::cstrings_test;

import c3io::event_loop;
import c3io::udp;
import c3io::tcp;
import c3io::file;
import c3io::uv;
import c3io::net;

// Copy `text` into a buffer with no null terminator and return the first
// `len` bytes as a String, so the byte after the slice is part of the text.
// (Slicing a literal directly is folded into a new null-terminated literal.)
fn String unterminated_slice(String text, usz len)
{
    char[] buf = mem::new_array(char, (sz)text.len);
    buf[..] = text[..];
    return (String)buf[:len];
}

fn void test_udp_bind_with_sliced_ip() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free();

    UdpSocket* socket = udp::create(&loop)!!;
    String ip = unterminated_slice("127.0.0.1:7777", 9);
    defer free(ip.ptr);
    socket.bind(net::addr(ip, 0)!!)!!;
    socket.close();
    while (loop.is_alive()) loop.run_once();
}

fn void test_tcp_bind_with_sliced_ip() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free();

    TcpConnection* server = tcp::create(&loop)!!;
    String ip = unterminated_slice("127.0.0.1:7777", 9);
    defer free(ip.ptr);
    server.bind(net::addr(ip, 0)!!)!!;
    server.close();
    while (loop.is_alive()) loop.run_once();
}

struct StatResult
{
    bool done;
    int status;
}

fn void on_stat(uv::FileStat* stat, int status, void* user_data)
{
    StatResult* result = user_data;
    result.done = true;
    result.status = status;
}

fn void test_stat_with_sliced_path() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free();

    // "." followed by bytes that would name a missing file if read.
    String path = unterminated_slice(".does-not-exist", 1);
    defer free(path.ptr);
    StatResult result;
    file::stat(&loop, path, &on_stat, &result);
    while (!result.done) loop.run_once();
    assert(result.status == 0, "stat of '.' should succeed");
}
