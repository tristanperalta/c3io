module c3io::dns;

import c3io;
import c3io::uv;
import c3io::event_loop;

<*
 Async DNS Resolution Wrapper for libuv
 =======================================
 Provides async DNS resolution using libuv's getaddrinfo API.

 All operations are non-blocking and use callbacks for completion.

 Usage:
   DnsResolver* resolver = dns::create(loop);
   resolver.resolve("example.com", "6881", &on_resolve, user_data)!;

   // In on_resolve callback:
   if (addrs) {
       for (AddrInfo* info = addrs; info != null; info = info.ai_next) {
           // Use info.ai_addr
       }
       dns::free_result(addrs);
   }
*>

// Faults
excuse DNS_RESOLVE_FAILED;

<*
 DNS Resolver
 Wraps an event loop for performing DNS queries.
*>
struct DnsResolver
{
    event_loop::EventLoop* loop;
    Allocator allocator;
}

// Callback types
alias ResolveCallback = fn void(uv::AddrInfo* result, int status, void* user_data);

// Request context structure
struct ResolveContext
{
    event_loop::PendingRequest pending;
    event_loop::EventLoop* loop;
    Allocator allocator;
    uv::GetAddrInfo* req;
    ResolveCallback cb;
    void* user_data;
}

// Internal libuv callback wrapper
fn void on_resolve_internal(uv::GetAddrInfo* req, int status, uv::AddrInfo* res)
{
    ResolveContext* ctx = uv::req_get(ResolveContext, req);
    ctx.loop.untrack(&ctx.pending);

    if (ctx.cb)
    {
        ctx.cb(res, status, ctx.user_data);
    }

    // Note: AddrInfo result is NOT freed here - caller must call free_result()
    alloc::free(ctx.allocator, ctx.req);
    alloc::free(ctx.allocator, ctx);
}

<*
 Create a new DNS resolver.

 @param loop : "Event loop to attach to"
 @param allocator : "Allocator for the resolver and its queries (default: the loop's)"
*>
fn DnsResolver* create(event_loop::EventLoop* loop, Allocator allocator = null){
    allocator = loop.allocator_or(allocator);
    DnsResolver* resolver = alloc::new(allocator, DnsResolver);
    resolver.loop = loop;
    resolver.allocator = allocator;
    return resolver;
}

<*
 Free the resolver. Queries already started still complete.
*>
fn void DnsResolver.free(&self){
    alloc::free(self.allocator, self);
}

fn event_loop::RequestId? DnsResolver.start_query(&self, String hostname, String service,
                                                 uv::AddrInfo* hints, ResolveCallback callback,
                                                 void* user_data)
{
    ResolveContext* ctx = alloc::new(self.allocator, ResolveContext);
    ctx.loop = self.loop;
    ctx.allocator = self.allocator;
    ctx.cb = callback;
    ctx.user_data = user_data;
    ctx.req = c3io::alloc_req(self.allocator, uv::GetAddrInfo, uv::ReqType.GETADDRINFO);
    uv::req_set(ctx.req, ctx);

    int result;
    @pool()
    {
        result = uv::getaddrinfo(self.loop.loop, ctx.req, &on_resolve_internal,
                                 hostname.zstr_tcopy(), service.zstr_tcopy(), hints);
    };
    if (result < 0)
    {
        alloc::free(self.allocator, ctx.req);
        alloc::free(self.allocator, ctx);
        c3io::set_last_status(result);
        return DNS_RESOLVE_FAILED~;
    }
    return self.loop.track(&ctx.pending, ctx.req);
}

<*
 Resolve a hostname to IP addresses for UDP use, asynchronously.
 Callback receives AddrInfo linked list. Caller must call free_result() to free it.

 @param hostname : "Hostname to resolve"
 @param service : "Numeric port"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
 @return "An id that can be passed to EventLoop.cancel()"
*>
fn event_loop::RequestId? DnsResolver.resolve(&self, String hostname, String service,
                                             ResolveCallback callback, void* user_data){
    uv::AddrInfo hints = {
        .ai_family = uv::AF_UNSPEC,
        .ai_socktype = uv::SOCK_DGRAM,
        .ai_protocol = uv::IPPROTO_UDP,
        .ai_flags = uv::AI_NUMERICSERV,
    };
    return self.start_query(hostname, service, &hints, callback, user_data);
}

<*
 Resolve a hostname for TCP connections asynchronously.

 @param hostname : "Hostname to resolve"
 @param service : "Numeric port"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
 @return "An id that can be passed to EventLoop.cancel()"
*>
fn event_loop::RequestId? DnsResolver.resolve_tcp(&self, String hostname, String service,
                                                 ResolveCallback callback, void* user_data){
    uv::AddrInfo hints = {
        .ai_family = uv::AF_UNSPEC,
        .ai_socktype = uv::SOCK_STREAM,
        .ai_protocol = uv::IPPROTO_TCP,
        .ai_flags = uv::AI_NUMERICSERV,
    };
    return self.start_query(hostname, service, &hints, callback, user_data);
}

<*
 Free the AddrInfo result returned by resolve().

 @param result : "AddrInfo linked list to free"
*>
fn void free_result(uv::AddrInfo* result){
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
fn String addr_to_string(uv::Sockaddr* addr){
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
