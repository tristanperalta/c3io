module c3io::work_test;

import c3io;
import c3io::event_loop;
import c3io::work;
import c3io::uv;
import std::thread;
import std::atomic;

// Libuv's default pool size; the tests don't set UV_THREADPOOL_SIZE.
const POOL_THREADS = 4;

// Set to 1 on the test's own thread; pool threads see 0.
tlocal int on_test_thread;

struct Job
{
    int input;
    int output;
    bool after_ran;
    int status;
    bool work_ran;
    int work_on_test_thread;
    int after_on_test_thread;
}

fn void square(void* arg)
{
    Job* job = arg;
    job.output = job.input * job.input;
    job.work_ran = true;
    job.work_on_test_thread = on_test_thread;
}

fn void record_after(void* arg, int status)
{
    Job* job = arg;
    job.after_ran = true;
    job.status = status;
    job.after_on_test_thread = on_test_thread;
}

fn void test_work_runs_on_pool_and_after_on_loop_thread() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    on_test_thread = 1;
    Job job = { .input = 7 };
    work::queue(&loop, &square, &record_after, &job)!!;
    while (!job.after_ran) loop.run_once();

    assert(job.status == 0);
    assert(job.output == 49);
    assert(job.after_on_test_thread == 1, "after runs on the loop thread");
    assert(job.work_on_test_thread == 0, "work runs on a pool thread");
    assert(loop.pending == null);
}

fn void sleep_100ms(void* arg)
{
    thread::sleep_ms(100);
}

fn void test_cancel_work_that_has_not_started() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    // Occupy every pool thread so the next job has to wait in the queue.
    Job[POOL_THREADS] busy;
    foreach (&b : busy) work::queue(&loop, &sleep_100ms, &record_after, b)!!;
    thread::sleep_ms(20);

    Job queued;
    event_loop::RequestId id = work::queue(&loop, &square, &record_after, &queued)!!;
    assert(loop.cancel(id), "Queued work should be cancellable");
    assert(!loop.cancel(id), "Cancelling twice does nothing");

    while (loop.is_alive()) loop.run_once();
    assert(queued.after_ran);
    assert(queued.status == uv::UV_ECANCELED);
    assert(!queued.work_ran, "Cancelled work never runs");
    foreach (b : busy) assert(b.status == 0, "Running work completes normally");
}

fn void test_cannot_cancel_running_or_finished_work() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    Job job;
    event_loop::RequestId id = work::queue(&loop, &sleep_100ms, &record_after, &job)!!;
    thread::sleep_ms(20);
    assert(!loop.cancel(id), "Running work can't be cancelled");
    while (!job.after_ran) loop.run_once();
    assert(job.status == 0);
    assert(!loop.cancel(id), "Finished work can't be cancelled");
}

fn void test_shutdown_cancels_queued_work() @test
{
    EventLoop loop = event_loop::create()!!;

    Job[POOL_THREADS] busy;
    foreach (&b : busy) work::queue(&loop, &sleep_100ms, &record_after, b)!!;
    thread::sleep_ms(20);
    Job queued;
    work::queue(&loop, &square, &record_after, &queued)!!;

    while (!loop.shutdown()) thread::sleep_ms(5);
    assert(queued.status == uv::UV_ECANCELED);
    loop.free()!!;
}

fn void test_queue_without_work_function_fails() @test
{
    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;
    if (try work::queue(&loop, null)) assert(false, "A work function is required");
    assert(loop.pending == null);
}

fn void test_work_uses_given_allocator() @test
{
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    EventLoop loop = event_loop::create()!!;
    defer loop.free()!!;

    Job job = { .input = 3 };
    work::queue(&loop, &square, &record_after, &job, &tracker)!!;
    assert(tracker.allocation_count() == 1, "One allocation per work item");
    while (!job.after_ran) loop.run_once();
    assert(tracker.allocation_count() == 0);
}
