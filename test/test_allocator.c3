module c3io::allocator_test;

import c3io::event_loop;
import c3io::udp;
import c3io::tcp;
import c3io::timer;
import c3io::dns;
import c3io::file;
import c3io::uv;

fn void on_stat(uv::FileStat* stat, int status, void* user_data)
{
    *(bool*)user_data = true;
}

fn void on_resolve(uv::AddrInfo* result, int status, void* user_data)
{
    dns::free_result(result);
    *(bool*)user_data = true;
}

<*
 Everything created on a loop uses the loop's allocator, and all of it is
 returned once the objects are closed and the loop is freed.
*>
fn void test_loop_allocator_is_used_and_released() @test
{
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    EventLoop loop = event_loop::create(&tracker)!!;

    UdpSocket* socket = udp::create(&loop)!!;
    TcpConnection* conn = tcp::create(&loop)!!;
    timer::Timer* t = timer::create(&loop)!!;
    DnsResolver* resolver = dns::create(&loop);

    bool stat_done;
    bool resolve_done;
    file::stat(&loop, ".", &on_stat, &stat_done);
    resolver.resolve("localhost", "80", &on_resolve, &resolve_done)!!;
    while (!stat_done || !resolve_done) loop.run_once();

    assert(tracker.allocation_count() > 0, "Objects should allocate from the loop's allocator");

    socket.close();
    conn.close();
    t.close();
    resolver.free();
    while (loop.is_alive()) loop.run_once();
    loop.free();

    assert(tracker.allocation_count() == 0, "Everything should be freed");
}

<*
 An allocator passed to create() overrides the loop's.
*>
fn void test_object_allocator_overrides_loop() @test
{
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    EventLoop loop = event_loop::create()!!;
    defer loop.free();

    UdpSocket* socket = udp::create(&loop, &tracker)!!;
    assert(tracker.allocation_count() == 2, "Handle and wrapper come from the given allocator");
    socket.close();
    while (loop.is_alive()) loop.run_once();
    assert(tracker.allocation_count() == 0);
}

<*
 close_all_handles closes handles the caller never closed, and frees their
 wrappers rather than leaking them.
*>
fn void test_close_all_handles_frees_wrappers() @test
{
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    EventLoop loop = event_loop::create(&tracker)!!;
    (void)udp::create(&loop)!!;
    (void)tcp::create(&loop)!!;
    (void)timer::create(&loop)!!;

    loop.close_all_handles();
    loop.free();
    assert(tracker.allocation_count() == 0, "Unclosed wrappers should be freed");
}

<*
 In-flight requests are tracked until their callback runs.
*>
fn void test_requests_are_tracked_until_complete() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free();
    DnsResolver* resolver = dns::create(&loop);
    defer resolver.free();

    bool done;
    event_loop::RequestId id = resolver.resolve("localhost", "80", &on_resolve, &done)!!;
    assert(id != (event_loop::RequestId)0);
    assert(loop.pending != null && loop.pending.id == id);
    while (!done) loop.run_once();
    assert(loop.pending == null, "Completed request should be untracked");
}

<*
 close_all_handles closes handles c3io didn't create without touching their
 data, leaving their memory to the caller.
*>
fn void test_close_all_handles_skips_foreign_handles() @test
{
    EventLoop loop = event_loop::create()!!;
    uv::Timer* raw = mem::calloc((sz)uv::handle_size(uv::HandleType.TIMER));
    assert(uv::timer_init(loop.loop, raw) == 0);
    int not_an_owner = 42;
    uv::handle_set_data(raw, &not_an_owner);

    loop.close_all_handles();
    loop.free();
    free(raw);
}
