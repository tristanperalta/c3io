module c3io::net_test;

import c3io;
import c3io::net;
import std::collections::map;

fn void test_parse_ipv4() @test
{
    SocketAddr a = net::addr("127.0.0.1", 7777)!!;
    assert(a.is_ipv4());
    assert(!a.is_ipv6());
    assert(a.port() == 7777);
    assert(string::tformat("%s", a) == "127.0.0.1:7777");
}

fn void test_parse_ipv6() @test
{
    SocketAddr a = net::addr("::1", 7777)!!;
    assert(a.is_ipv6());
    assert(a.port() == 7777);
    assert(string::tformat("%s", a) == "[::1]:7777");
}

fn void test_parse_invalid_address() @test
{
    if (try net::addr("300.1.1.1", 80)) assert(false, "Out-of-range octet should fail");
    assert(c3io::last_status() < 0);
    if (try net::addr("not-an-ip", 80)) assert(false, "Hostname should fail");
}

fn void test_parse_endpoint() @test
{
    SocketAddr v4 = net::parse_endpoint("10.0.0.2:1234")!!;
    assert(string::tformat("%s", v4) == "10.0.0.2:1234");

    SocketAddr v6 = net::parse_endpoint("[fe80::1]:80")!!;
    assert(v6.is_ipv6() && v6.port() == 80);

    String[] bad = { "10.0.0.2", "::1:80", "[::1]80", "10.0.0.2:70000", "10.0.0.2:", "[::1:80" };
    foreach (text : bad)
    {
        if (try net::parse_endpoint(text)) assert(false, "Should reject %s", text);
    }
}

fn void test_equality() @test
{
    SocketAddr a = net::addr("192.168.1.10", 5000)!!;
    SocketAddr b = net::parse_endpoint("192.168.1.10:5000")!!;
    SocketAddr other_port = net::addr("192.168.1.10", 5001)!!;
    SocketAddr other_ip = net::addr("192.168.1.11", 5000)!!;
    SocketAddr v6 = net::addr("::ffff:192.168.1.10", 5000)!!;

    assert(a == b);
    assert(a.hash() == b.hash());
    assert(!(a == other_port));
    assert(!(a == other_ip));
    assert(!(a == v6), "IPv4 and IPv4-mapped IPv6 are different addresses");
}

fn void test_as_hashmap_key() @test
{
    HashMap{SocketAddr, int} peers;
    peers.init(mem);
    defer peers.free();

    peers.set(net::addr("10.0.0.1", 7000)!!, 1);
    peers.set(net::addr("::1", 7000)!!, 2);

    assert(peers.get(net::parse_endpoint("10.0.0.1:7000")!!)!! == 1);
    assert(peers.get(net::parse_endpoint("[::1]:7000")!!)!! == 2);
    assert(!@ok(peers.get(net::addr("10.0.0.1", 7001)!!)));
}

fn void test_from_sockaddr_round_trip() @test
{
    SocketAddr a = net::addr("2001:db8::5", 443)!!;
    SocketAddr copy = net::from_sockaddr(a.sockaddr());
    assert(copy == a);
    assert(net::from_sockaddr(null).port() == 0);
}
