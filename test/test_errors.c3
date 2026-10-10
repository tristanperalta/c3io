module c3io::errors_test;

import c3io;
import c3io::event_loop;
import c3io::udp;

fn void test_failed_call_records_status() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free();

    UdpSocket* socket = udp::create(&loop)!!;
    if (catch err = socket.bind("not-an-ip", 0))
    {
        assert(err == udp::UDP_BIND_FAILED);
        assert(c3io::last_status() < 0);
        assert(c3io::error_name(c3io::last_status()) == "EINVAL");
        assert(c3io::error_message(c3io::last_status()).len > 0);
    }
    else
    {
        assert(false, "Binding an invalid address should fail");
    }

    socket.close();
    while (loop.is_alive()) loop.run_once();
}
