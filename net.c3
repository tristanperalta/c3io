module c3io::net;

import c3io;
import c3io::uv;
import std::hash::fnv32a;
import std::io;
import std::bits;

<*
 Socket addresses
 ================
 A SocketAddr holds an IPv4 or IPv6 address and port by value. Parse it once
 and reuse it for every send to the same peer. It can be compared with `==`
 and used as a HashMap key, so a server can look up the peer a datagram came
 from.

 Usage:
   SocketAddr server = net::addr("127.0.0.1", 7777)!;
   SocketAddr any_v6 = net::addr("::", 7777)!;
   SocketAddr peer = net::parse_endpoint("[::1]:7777")!;
   io::printfn("%s", peer);  // [::1]:7777
*>

excuse INVALID_ADDRESS;

struct SocketAddr (Printable)
{
    union
    {
        uv::Sockaddr base;
        uv::Sockaddr_in v4;
        uv::Sockaddr_in6 v6;
    }
}

<*
 Parse an IP address and port. The address family follows the text: an
 address containing ':' is IPv6, anything else is IPv4.

 @param ip : "Numeric IPv4 or IPv6 address, without brackets"
 @param port : "Port number"
*>
fn SocketAddr? addr(String ip, ushort port)
{
    SocketAddr result;
    int status;
    @pool()
    {
        ZString z = ip.zstr_tcopy();
        if (ip.contains_char(':'))
        {
            status = uv::ip6_addr(z, port, &result.v6);
        }
        else
        {
            status = uv::ip4_addr(z, port, &result.v4);
        }
    };
    c3io::@check(status, INVALID_ADDRESS)!;
    return result;
}

<*
 Parse "ip:port" for IPv4 or "[ip]:port" for IPv6.
*>
fn SocketAddr? parse_endpoint(String text)
{
    String ip;
    String port_text;
    if (text.starts_with("["))
    {
        sz close = text.index_of("]:") ?? -1;
        if (close < 0) return INVALID_ADDRESS~;
        ip = text[1:close - 1];
        port_text = text[close + 2..];
    }
    else
    {
        sz colon = text.rindex_of_char(':') ?? -1;
        if (colon < 0) return INVALID_ADDRESS~;
        ip = text[:colon];
        port_text = text[colon + 1..];
        if (ip.contains_char(':')) return INVALID_ADDRESS~;  // IPv6 needs brackets
    }
    ushort? port = port_text.to_ushort();
    if (catch port) return INVALID_ADDRESS~;
    return addr(ip, port);
}

<*
 Copy a sockaddr returned by libuv (an IPv4 or IPv6 one) into a SocketAddr.
*>
fn SocketAddr from_sockaddr(uv::Sockaddr* sa)
{
    SocketAddr result;
    if (!sa) return result;
    if ((int)sa.sa_family == uv::AF_INET6)
    {
        result.v6 = *(uv::Sockaddr_in6*)sa;
    }
    else
    {
        result.v4 = *(uv::Sockaddr_in*)sa;
    }
    return result;
}

<*
 The first address of a DNS result.
*>
fn SocketAddr? from_addrinfo(uv::AddrInfo* info)
{
    if (!info || !info.ai_addr) return INVALID_ADDRESS~;
    return from_sockaddr(info.ai_addr);
}

<*
 Pointer to pass to libuv calls that take a `const struct sockaddr*`.
*>
fn uv::Sockaddr* SocketAddr.sockaddr(&self) => &self.base;

fn bool SocketAddr.is_ipv6(&self) => (int)self.base.sa_family == uv::AF_INET6;

fn bool SocketAddr.is_ipv4(&self) => (int)self.base.sa_family == uv::AF_INET;

<*
 The port in host byte order.
*>
fn ushort SocketAddr.port(&self)
{
    ushort port = self.is_ipv6() ? self.v6.sin6_port : self.v4.sin_port;
    $if env::BIG_ENDIAN:
        return port;
    $else
        return bswap(port);
    $endif
}

<*
 True if both hold the same family, address and port (and, for IPv6, the
 same scope).
*>
fn bool SocketAddr.equals(&self, SocketAddr* other)
{
    if (self.base.sa_family != other.base.sa_family) return false;
    if (self.is_ipv6())
    {
        return self.v6.sin6_port == other.v6.sin6_port
            && self.v6.sin6_addr == other.v6.sin6_addr
            && self.v6.sin6_scope_id == other.v6.sin6_scope_id;
    }
    if (self.is_ipv4())
    {
        return self.v4.sin_port == other.v4.sin_port
            && self.v4.sin_addr == other.v4.sin_addr;
    }
    return true;
}

fn bool SocketAddr.eq(self, SocketAddr other) @operator(==) => self.equals(&other);

<*
 Hash of the family, address and port, consistent with equals().
*>
fn uint SocketAddr.hash(self)
{
    Fnv32a h;
    h.init();
    h.update_byte((char)self.base.sa_family);
    if (self.is_ipv6())
    {
        h.update(@as_char_view(self.v6.sin6_port));
        h.update(&self.v6.sin6_addr);
        h.update(@as_char_view(self.v6.sin6_scope_id));
    }
    else if (self.is_ipv4())
    {
        h.update(@as_char_view(self.v4.sin_port));
        h.update(@as_char_view(self.v4.sin_addr));
    }
    return (uint)h;
}

<*
 Formats as "1.2.3.4:5" or "[::1]:5".
*>
fn sz? SocketAddr.to_format(&self, Formatter* f) @dynamic
{
    char[64] buf;
    if (self.is_ipv6())
    {
        if (uv::ip6_name(&self.v6, &buf, buf.len) < 0) return f.print("[invalid]");
        return f.printf("[%s]:%d", (ZString)&buf, self.port());
    }
    if (self.is_ipv4())
    {
        if (uv::ip4_name(&self.v4, &buf, buf.len) < 0) return f.print("invalid");
        return f.printf("%s:%d", (ZString)&buf, self.port());
    }
    return f.print("unspecified");
}
