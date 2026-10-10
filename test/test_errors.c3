module c3io::errors_test;

import c3io;
import c3io::event_loop;
import c3io::udp;
import c3io::net;

fn void test_failed_call_records_status() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    UdpSocket* socket = udp::create(&loop)!!;
    // 192.0.2.1 is reserved for documentation (TEST-NET-1), so no local
    // interface has it.
    if (catch err = socket.bind(net::addr("192.0.2.1", 0)!!))
    {
        assert(err == udp::UDP_BIND_FAILED);
        assert(c3io::last_status() < 0);
        assert(c3io::error_name(c3io::last_status()) == "EADDRNOTAVAIL");
        assert(c3io::error_message(c3io::last_status()).len > 0);
    }
    else
    {
        assert(false, "Binding a non-local address should fail");
    }

    socket.close();
    while (loop.is_alive()) loop.run_once();
}
