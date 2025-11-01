module async::dns;

import uv;
import std::io;
import async::event_loop;

<*
 Async DNS Resolution Wrapper for libuv
 =======================================
 Provides async DNS resolution using libuv's getaddrinfo API.

 All operations are non-blocking and use callbacks for completion.

 Usage:
   async_dns::resolve(loop, "example.com", "6881", &on_resolve, user_data);

   // In on_resolve callback:
   if (addrs) {
       for (AddrInfo* info = addrs; info != null; info = info.ai_next) {
           // Use info.ai_addr
       }
       async_dns::free_result(addrs);
   }
*>

// Faults
faultdef DNS_RESOLVE_FAILED;

<*
 DNS Resolver
 Wraps an event loop for performing DNS queries.
*>
struct DnsResolver
{
    event_loop::EventLoop* loop;
}

// Callback types
alias ResolveCallback = fn void(uv::AddrInfo* result, int status, void* user_data);

// Request context structure
struct ResolveContext
{
    uv::GetAddrInfo* req;
    ResolveCallback cb;
    void* user_data;
}

// Internal libuv callback wrapper
fn void on_resolve_internal(uv::GetAddrInfo* req, int status, uv::AddrInfo* res)
{
    ResolveContext* ctx = uv::req_get(ResolveContext, req);

    if (ctx.cb)
    {
        ctx.cb(res, status, ctx.user_data);
    }

    // Note: AddrInfo result is NOT freed here - caller must call free_result()
    free(ctx.req);
    free(ctx);
}

<*
 Create a new DNS resolver.

 @param loop : "Event loop to attach to"
*>
fn DnsResolver* create(event_loop::EventLoop* loop) @public
{
    DnsResolver* resolver = mem::new(DnsResolver);
    resolver.loop = loop;
    return resolver;
}

<*
 Resolve a hostname to IP addresses asynchronously.
 Callback receives AddrInfo linked list. Caller must call free_result() to free it.

 @param hostname : "Hostname to resolve"
 @param service : "Service name or port number"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void DnsResolver.resolve(&self, String hostname, String service,
                            ResolveCallback callback, void* user_data) @public
{
    ResolveContext* ctx = mem::new(ResolveContext);
    ctx.cb = callback;
    ctx.user_data = user_data;

    // Allocate request
    ctx.req = uv::alloc_req(uv::GetAddrInfo);
    uv::req_set(ctx.req, ctx);

    // Prepare hints for UDP socket
    uv::AddrInfo hints;
    hints.ai_family = uv::AF_UNSPEC;      // Allow IPv4 or IPv6
    hints.ai_socktype = uv::SOCK_DGRAM;   // UDP socket
    hints.ai_protocol = uv::IPPROTO_UDP;  // UDP protocol
    hints.ai_flags = uv::AI_NUMERICSERV;  // Service is a numeric port

    ZString c_hostname = (ZString)hostname.ptr;
    ZString c_service = (ZString)service.ptr;

    int result = uv::getaddrinfo(self.loop.loop, ctx.req, &on_resolve_internal,
                                 c_hostname, c_service, &hints);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(null, result, user_data);
        }
        free(ctx.req);
        free(ctx);
    }
}

<*
 Resolve a hostname for TCP connections asynchronously.

 @param hostname : "Hostname to resolve"
 @param service : "Service name or port number"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void DnsResolver.resolve_tcp(&self, String hostname, String service,
                                ResolveCallback callback, void* user_data) @public
{
    ResolveContext* ctx = mem::new(ResolveContext);
    ctx.cb = callback;
    ctx.user_data = user_data;

    // Allocate request
    ctx.req = uv::alloc_req(uv::GetAddrInfo);
    uv::req_set(ctx.req, ctx);

    // Prepare hints for TCP socket
    uv::AddrInfo hints;
    hints.ai_family = uv::AF_UNSPEC;      // Allow IPv4 or IPv6
    hints.ai_socktype = uv::SOCK_STREAM;  // TCP socket
    hints.ai_protocol = uv::IPPROTO_TCP;  // TCP protocol
    hints.ai_flags = uv::AI_NUMERICSERV;  // Service is a numeric port

    ZString c_hostname = (ZString)hostname.ptr;
    ZString c_service = (ZString)service.ptr;

    int result = uv::getaddrinfo(self.loop.loop, ctx.req, &on_resolve_internal,
                                 c_hostname, c_service, &hints);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(null, result, user_data);
        }
        free(ctx.req);
        free(ctx);
    }
}

<*
 Free the AddrInfo result returned by resolve().

 @param result : "AddrInfo linked list to free"
*>
fn void free_result(uv::AddrInfo* result) @public
{
    if (result)
    {
        uv::freeaddrinfo(result);
    }
}

<*
 Convert a Sockaddr to a string representation.
 Returns empty string on error.

 @param addr : "Socket address to convert"
*>
fn String addr_to_string(uv::Sockaddr* addr) @public
{
    if (!addr) return "";

    if (addr.sa_family == uv::AF_INET)
    {
        // IPv4
        uv::Sockaddr_in* addr4 = (uv::Sockaddr_in*)addr;
        char[32] buffer;
        int result = uv::ip4_name(addr4, &buffer, 32);
        if (result < 0) return "";
        return ((ZString)&buffer).copy(mem);
    }
    else if (addr.sa_family == uv::AF_INET6)
    {
        // IPv6
        uv::Sockaddr_in6* addr6 = (uv::Sockaddr_in6*)addr;
        char[64] buffer;
        int result = uv::ip6_name(addr6, &buffer, 64);
        if (result < 0) return "";
        return ((ZString)&buffer).copy(mem);
    }

    return "";
}
