module async::file::test;

import async::file;
import async::event_loop;
import uv;
import std::io;

// Test result tracking
struct TestContext
{
    bool success;
    bool completed;
    int error_code;
    async::file::FileHandle* file;
    char[] data;
    usz bytes_written;
    usz file_size;
    event_loop::EventLoop* loop;
}

// ============================================================================
// Open/Close Tests
// ============================================================================

fn void on_close_success(int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.success = (status == 0);
    ctx.error_code = status;
}

fn void on_open_then_close(async::file::FileHandle* file, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.file = file;
    file.close(&on_close_success, user_data);
}

fn void test_open_close_file() @test
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

    // Open a temporary test file
    async::file::open(&loop, "/tmp/test_async_file_temp.txt",
                     async::file::OPEN_RDWR | async::file::OPEN_CREATE,
                     420, &on_open_then_close, &ctx);

    // Run event loop until complete
    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "File open/close should succeed");
    assert(ctx.error_code == 0, "Should have no errors");
}

// ============================================================================
// Write/Read Tests
// ============================================================================

fn void on_read_verify(char[] data, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;

    if (status < 0)
    {
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Verify we read the expected data
    String expected = "Hello async file I/O!";
    ctx.success = (data.len == expected.len);

    if (ctx.success)
    {
        for (usz i = 0; i < data.len; i++)
        {
            if (data[i] != expected[i])
            {
                ctx.success = false;
                break;
            }
        }
    }
}

fn void on_write_then_read(int bytes_written, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.bytes_written = (usz)bytes_written;

    // Now read back the data
    ctx.file.read(0, (usz)bytes_written, &on_read_verify, user_data);
}

fn void on_open_for_write(async::file::FileHandle* file, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.file = file;

    // Write some data
    String test_data = "Hello async file I/O!";
    file.write(0, (char[])test_data, &on_write_then_read, user_data);
}

fn void test_write_read_file() @test
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

    async::file::open(&loop, "/tmp/test_async_rw.txt",
                     async::file::OPEN_RDWR | async::file::OPEN_CREATE | async::file::OPEN_TRUNC,
                     420, &on_open_for_write, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Write/read should succeed");
    assert(ctx.bytes_written == 21, "Should write 21 bytes");

    // Clean up
    ctx.file.close(&on_close_success, &ctx);
    ctx.completed = false;
    while (!ctx.completed)
    {
        loop.run_once();
    }
}

// ============================================================================
// Stat Tests
// ============================================================================

fn void on_stat_verify(uv::FileStat* stat, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;

    if (status < 0 || !stat)
    {
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.file_size = (usz)stat.st_size;
    ctx.success = (ctx.file_size > 0);  // File should have content
}

fn void on_close_before_stat(int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Now stat the file
    async::file::stat(ctx.loop, "/tmp/test_async_stat.txt", &on_stat_verify, user_data);
}

fn void on_write_for_stat(int bytes_written, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Close file first
    ctx.file.close(&on_close_before_stat, user_data);
}

fn void on_open_for_stat(async::file::FileHandle* file, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.file = file;

    String test_data = "Test file stat";
    file.write(0, (char[])test_data, &on_write_for_stat, user_data);
}

fn void test_stat_file() @test
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

    async::file::open(&loop, "/tmp/test_async_stat.txt",
                     async::file::OPEN_RDWR | async::file::OPEN_CREATE | async::file::OPEN_TRUNC,
                     420, &on_open_for_stat, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Stat should succeed");
    assert(ctx.file_size == 14, "File size should be 14 bytes");
}

// ============================================================================
// Truncate Tests
// ============================================================================

fn void on_truncate_verify(int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.success = (status == 0);
    ctx.error_code = status;
}

fn void on_open_for_truncate(async::file::FileHandle* file, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.file = file;

    // Truncate to 1MB
    file.ftruncate(1048576, &on_truncate_verify, user_data);
}

fn void test_ftruncate_file() @test
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

    async::file::open(&loop, "/tmp/test_async_truncate.txt",
                     async::file::OPEN_RDWR | async::file::OPEN_CREATE | async::file::OPEN_TRUNC,
                     420, &on_open_for_truncate, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Truncate should succeed");

    // Clean up
    ctx.file.close(&on_close_success, &ctx);
    ctx.completed = false;
    while (!ctx.completed)
    {
        loop.run_once();
    }
}

// ============================================================================
// Mkdir Tests
// ============================================================================

fn void on_mkdir_verify(int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    // Mkdir may fail if directory exists, so accept EEXIST
    ctx.success = (status == 0 || status == -17);  // 0 or EEXIST
    ctx.error_code = status;
}

fn void test_mkdir() @test
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

    async::file::mkdir(&loop, "/tmp/test_async_dir", 493, &on_mkdir_verify, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Mkdir should succeed or already exist");
}

// ============================================================================
// Error Handling Tests
// ============================================================================

fn void on_open_nonexistent(async::file::FileHandle* file, int status, void* user_data)
{
    TestContext* ctx = (TestContext*)user_data;
    ctx.completed = true;
    ctx.success = (status < 0);  // Should fail
    ctx.error_code = status;
}

fn void test_open_nonexistent_file() @test
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

    // Try to open non-existent file without CREATE flag
    async::file::open(&loop, "/nonexistent/path/file.txt",
                     async::file::OPEN_RDONLY, 420,
                     &on_open_nonexistent, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Opening nonexistent file should fail");
    assert(ctx.error_code < 0, "Should have error code");
}
