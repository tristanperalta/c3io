module async::file::test;

import async::file;
import async::event_loop;
import uv;
import std::io;

// Test result tracking
struct ScandirTestContext
{
    bool success;
    bool completed;
    int error_code;
    usz num_entries;
    bool found_file1;
    bool found_file2;
    bool found_subdir;
    event_loop::EventLoop* loop;
}

// ============================================================================
// Scandir Tests
// ============================================================================

fn void on_scandir_verify(async::file::DirEntry[] entries, int status, void* user_data)
{
    ScandirTestContext* ctx = (ScandirTestContext*)user_data;
    ctx.completed = true;

    if (status < 0)
    {
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    ctx.num_entries = entries.len;

    // Check for expected entries
    for (usz i = 0; i < entries.len; i++)
    {
        if (entries[i].name == "test_file1.txt")
        {
            ctx.found_file1 = true;
        }
        else if (entries[i].name == "test_file2.txt")
        {
            ctx.found_file2 = true;
        }
        else if (entries[i].name == "test_subdir")
        {
            ctx.found_subdir = true;
            // Verify it's marked as a directory
            ctx.success = (entries[i].type == uv::DirEntryType.DIR);
        }
    }

    // Success if we found all expected entries
    ctx.success = ctx.found_file1 && ctx.found_file2 && ctx.found_subdir;
}

fn void on_mkdir_subdir(int status, void* user_data)
{
    ScandirTestContext* ctx = (ScandirTestContext*)user_data;

    // Ignore EEXIST error (directory already exists)
    if (status < 0 && status != -17)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Now scan the directory
    async::file::scandir(ctx.loop, "/tmp/test_scandir", &on_scandir_verify, user_data);
}

fn void on_close_file2(int status, void* user_data)
{
    ScandirTestContext* ctx = (ScandirTestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Create subdirectory
    async::file::mkdir(ctx.loop, "/tmp/test_scandir/test_subdir", 493, &on_mkdir_subdir, user_data);
}

fn void on_open_file2(async::file::FileHandle* file, int status, void* user_data)
{
    ScandirTestContext* ctx = (ScandirTestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Close immediately (we just need the file to exist)
    file.close(&on_close_file2, user_data);
}

fn void on_close_file1(int status, void* user_data)
{
    ScandirTestContext* ctx = (ScandirTestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Create second test file
    async::file::open(ctx.loop, "/tmp/test_scandir/test_file2.txt",
                     async::file::OPEN_RDWR | async::file::OPEN_CREATE,
                     420, &on_open_file2, user_data);
}

fn void on_open_file1(async::file::FileHandle* file, int status, void* user_data)
{
    ScandirTestContext* ctx = (ScandirTestContext*)user_data;

    if (status < 0)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Close immediately (we just need the file to exist)
    file.close(&on_close_file1, user_data);
}

fn void on_mkdir_base(int status, void* user_data)
{
    ScandirTestContext* ctx = (ScandirTestContext*)user_data;

    // Ignore EEXIST error (directory already exists)
    if (status < 0 && status != -17)
    {
        ctx.completed = true;
        ctx.success = false;
        ctx.error_code = status;
        return;
    }

    // Create first test file
    async::file::open(ctx.loop, "/tmp/test_scandir/test_file1.txt",
                     async::file::OPEN_RDWR | async::file::OPEN_CREATE,
                     420, &on_open_file1, user_data);
}

fn void test_scandir_basic() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    ScandirTestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.found_file1 = false;
    ctx.found_file2 = false;
    ctx.found_subdir = false;
    ctx.loop = &loop;

    // Create test directory structure:
    // /tmp/test_scandir/
    //   ├── test_file1.txt
    //   ├── test_file2.txt
    //   └── test_subdir/

    // Create base directory first (will trigger the rest of the setup)
    async::file::mkdir(&loop, "/tmp/test_scandir", 493, &on_mkdir_base, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Scandir should succeed and find all entries");
    assert(ctx.num_entries >= 3, "Should find at least 3 entries (2 files + 1 dir)");
    assert(ctx.found_file1, "Should find test_file1.txt");
    assert(ctx.found_file2, "Should find test_file2.txt");
    assert(ctx.found_subdir, "Should find test_subdir");
}

// ============================================================================
// Error Handling Tests
// ============================================================================

fn void on_scandir_nonexistent(async::file::DirEntry[] entries, int status, void* user_data)
{
    ScandirTestContext* ctx = (ScandirTestContext*)user_data;
    ctx.completed = true;
    ctx.success = (status < 0);  // Should fail
    ctx.error_code = status;
    ctx.num_entries = entries.len;
}

fn void test_scandir_nonexistent() @test
{
    EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        assert(false, "Should create event loop");
        return;
    }
    EventLoop loop = loop_opt;
    defer loop.free();

    ScandirTestContext ctx;
    ctx.success = false;
    ctx.completed = false;
    ctx.loop = &loop;

    // Try to scan non-existent directory
    async::file::scandir(&loop, "/nonexistent/directory/path", &on_scandir_nonexistent, &ctx);

    while (!ctx.completed)
    {
        loop.run_once();
    }

    assert(ctx.success, "Scanning nonexistent directory should fail");
    assert(ctx.error_code < 0, "Should have error code");
    assert(ctx.num_entries == 0, "Should return empty array on error");
}
