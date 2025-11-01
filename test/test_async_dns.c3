module async::dns::test;

import async::dns;
import async::event_loop;
import uv;
import std::io;

// Test result tracking
struct TestContext
{
    bool success;
    bool completed;
    int error_code;
    event_loop::EventLoop* loop;
    uv::AddrInfo* result;
    int addr_count;
}

// ============================================================================
// DNS Resolution Tests
// ============================================================================

fn void on_resolve_localhost(uv::AddrInfo* result, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;

    if (status < 0 || !result)
    {
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.result = result;
    ctx.success = true;

    // Count addresses
    int count = 0;
    for (uv::AddrInfo* info = result; info != null; info = info.ai_next)
    {
        count++;
    }
    ctx.addr_count = count;
}

fn void test_resolve_localhost() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;
    ctx.result = null;
    ctx.addr_count = 0;

    // Create DNS resolver
    async::dns::DnsResolver* resolver = async::dns::create(&loop);
    defer free(resolver);

    // Resolve localhost (should always work)
    resolver.resolve("localhost", "8080", &on_resolve_localhost, &ctx);

    // Run event loop until complete
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Localhost resolution should succeed");
    assert(ctx.addr_count > 0, "Should have at least one address");

    // Clean up
    if (ctx.result)
    {
        async::dns::free_result(ctx.result);
    }
}

// ============================================================================
// TCP Resolution Tests
// ============================================================================

fn void on_resolve_tcp(uv::AddrInfo* result, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;

    if (status < 0 || !result)
    {
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.result = result;
    ctx.success = true;

    // Verify it's a TCP socket
    for (uv::AddrInfo* info = result; info != null; info = info.ai_next)
    {
        if (info.ai_socktype != uv::SOCK_STREAM)
        {
            ctx.success = false;
            return;
        }
    }
}

fn void test_resolve_tcp() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;
    ctx.result = null;

    // Create DNS resolver
    async::dns::DnsResolver* resolver = async::dns::create(&loop);
    defer free(resolver);

    // Resolve with TCP hint
    resolver.resolve_tcp("localhost", "80", &on_resolve_tcp, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "TCP resolution should succeed");

    // Clean up
    if (ctx.result)
    {
        async::dns::free_result(ctx.result);
    }
}

// ============================================================================
// Address to String Tests
// ============================================================================

fn void on_resolve_for_addr_to_string(uv::AddrInfo* result, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;

    if (status < 0 || !result)
    {
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.result = result;

    // Convert first address to string
    String addr_str = async::dns::addr_to_string(result.ai_addr);

    // Should be non-empty for localhost
    ctx.success = (addr_str.len > 0);

    // For localhost, expect 127.0.0.1 or ::1
    if (ctx.success)
    {
        bool is_ipv4_localhost = addr_str == "127.0.0.1";
        bool is_ipv6_localhost = addr_str == "::1";
        ctx.success = is_ipv4_localhost || is_ipv6_localhost;
    }

    free(addr_str);
}

fn void test_addr_to_string() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;
    ctx.result = null;

    // Create DNS resolver
    async::dns::DnsResolver* resolver = async::dns::create(&loop);
    defer free(resolver);

    resolver.resolve("localhost", "0", &on_resolve_for_addr_to_string, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Address to string conversion should succeed");

    // Clean up
    if (ctx.result)
    {
        async::dns::free_result(ctx.result);
    }
}

// ============================================================================
// Error Handling Tests
// ============================================================================

fn void on_resolve_invalid(uv::AddrInfo* result, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.success = (status < 0);  // Should fail
    ctx.error_code = status;
    ctx.result = result;
}

fn void test_resolve_invalid_hostname() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;
    ctx.result = null;

    // Create DNS resolver
    async::dns::DnsResolver* resolver = async::dns::create(&loop);
    defer free(resolver);

    // Try to resolve a clearly invalid hostname
    resolver.resolve("this-hostname-should-not-exist-12345.invalid",
                    "8080", &on_resolve_invalid, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Invalid hostname resolution should fail");
    assert(ctx.error_code < 0, "Should have error code");

    // Clean up (even though it should be null)
    if (ctx.result)
    {
        async::dns::free_result(ctx.result);
    }
}

// ============================================================================
// Multiple Address Tests
// ============================================================================

fn void on_resolve_multiple_addrs(uv::AddrInfo* result, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;

    if (status < 0 || !result)
    {
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.result = result;

    // Count addresses (localhost can have both IPv4 and IPv6)
    int count = 0;
    for (uv::AddrInfo* info = result; info != null; info = info.ai_next)
    {
        count++;
    }

    ctx.addr_count = count;
    ctx.success = (count >= 1);  // At least one address
}

fn void test_multiple_addresses() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    TestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;
    ctx.result = null;
    ctx.addr_count = 0;

    // Create DNS resolver
    async::dns::DnsResolver* resolver = async::dns::create(&loop);
    defer free(resolver);

    // Resolve localhost which may have multiple addresses
    resolver.resolve("localhost", "0", &on_resolve_multiple_addrs, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Multiple address resolution should succeed");
    assert(ctx.addr_count >= 1, "Should have at least one address");

    // Clean up
    if (ctx.result)
    {
        async::dns::free_result(ctx.result);
    }
}
