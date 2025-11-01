module async::file;

import uv;
import std::io;
import async::event_loop;

<*
 Async File I/O Wrapper for libuv
 =================================
 Provides async file operations using libuv's filesystem APIs.

 All operations are non-blocking and use callbacks for completion.

 Usage:
   async_file::open(loop, "data.txt", OPEN_RDWR | OPEN_CREATE, 0644, &on_open, user_data);

   // In on_open callback:
   async_file::write(file, 0, data[..], &on_write, user_data);
   async_file::close(file, &on_close, user_data);
*>

// File open flags (map to uv constants)
const int OPEN_RDONLY = 0x0000;  // O_RDONLY
const int OPEN_WRONLY = 0x0001;  // O_WRONLY
const int OPEN_RDWR   = 0x0002;  // O_RDWR
const int OPEN_CREATE = 0x0040;  // O_CREAT
const int OPEN_TRUNC  = 0x0200;  // O_TRUNC
const int OPEN_APPEND = 0x0400;  // O_APPEND

// Faults
faultdef FILE_OPEN_FAILED;
faultdef FILE_READ_FAILED;
faultdef FILE_WRITE_FAILED;
faultdef FILE_CLOSE_FAILED;
faultdef FILE_STAT_FAILED;
faultdef FILE_TRUNCATE_FAILED;
faultdef DIR_CREATE_FAILED;

// File handle (wraps uv file descriptor and event loop)
struct FileHandle
{
    int fd;
    event_loop::EventLoop* loop;
}

// Backwards compatibility typedef
typedef File = int;

// Callback types
alias OpenCallback = fn void(FileHandle* file, int status, void* user_data);
alias ReadCallback = fn void(char[] data, int status, void* user_data);
alias WriteCallback = fn void(int bytes_written, int status, void* user_data);
alias CloseCallback = fn void(int status, void* user_data);
alias StatCallback = fn void(uv::FileStat* stat, int status, void* user_data);
alias TruncateCallback = fn void(int status, void* user_data);
alias FsyncCallback = fn void(int status, void* user_data);
alias MkdirCallback = fn void(int status, void* user_data);

// Request context structures
struct OpenContext
{
    uv::Fs req;
    OpenCallback cb;
    void* user_data;
    event_loop::EventLoop* loop;
}

struct ReadContext
{
    uv::Fs req;
    uv::Buf buf;
    ReadCallback cb;
    void* user_data;
}

struct WriteContext
{
    uv::Fs req;
    uv::Buf buf;
    WriteCallback cb;
    void* user_data;
}

struct CloseContext
{
    uv::Fs req;
    CloseCallback cb;
    void* user_data;
}

struct StatContext
{
    uv::Fs req;
    StatCallback cb;
    void* user_data;
}

struct TruncateContext
{
    uv::Fs req;
    TruncateCallback cb;
    void* user_data;
}

struct FsyncContext
{
    uv::Fs req;
    FsyncCallback cb;
    void* user_data;
}

struct MkdirContext
{
    uv::Fs req;
    MkdirCallback cb;
    void* user_data;
}

// Internal libuv callback wrappers
fn void on_open_internal(uv::Fs* req)
{
    OpenContext* ctx = (OpenContext*)req;
    int result = (int)uv::fs_req_result(req);

    if (ctx.cb)
    {
        FileHandle* file = null;
        if (result >= 0)
        {
            // Success - create FileHandle
            file = mem::new(FileHandle);
            file.fd = result;
            file.loop = ctx.loop;
        }
        ctx.cb(file, result < 0 ? result : 0, ctx.user_data);
    }

    uv::fs_req_cleanup(req);
    free(ctx);
}

fn void on_read_internal(uv::Fs* req)
{
    ReadContext* ctx = (ReadContext*)req;
    int result = (int)uv::fs_req_result(req);

    if (ctx.cb)
    {
        char[] data = {};
        if (result > 0)
        {
            data = ((char*)ctx.buf.base)[:result];
        }
        ctx.cb(data, result < 0 ? result : 0, ctx.user_data);
    }

    // Free the buffer we allocated
    if (ctx.buf.base)
    {
        free(ctx.buf.base);
    }

    uv::fs_req_cleanup(req);
    free(ctx);
}

fn void on_write_internal(uv::Fs* req)
{
    WriteContext* ctx = (WriteContext*)req;
    int result = (int)uv::fs_req_result(req);

    if (ctx.cb)
    {
        ctx.cb(result >= 0 ? result : 0, result < 0 ? result : 0, ctx.user_data);
    }

    uv::fs_req_cleanup(req);
    free(ctx);
}

fn void on_close_internal(uv::Fs* req)
{
    CloseContext* ctx = (CloseContext*)req;
    int result = (int)uv::fs_req_result(req);

    if (ctx.cb)
    {
        ctx.cb(result, ctx.user_data);
    }

    uv::fs_req_cleanup(req);
    free(ctx);
}

fn void on_stat_internal(uv::Fs* req)
{
    StatContext* ctx = (StatContext*)req;
    int result = (int)uv::fs_req_result(req);

    if (ctx.cb)
    {
        uv::FileStat* stat = result >= 0 ? uv::fs_req_statbuf(req) : null;
        ctx.cb(stat, result, ctx.user_data);
    }

    uv::fs_req_cleanup(req);
    free(ctx);
}

fn void on_truncate_internal(uv::Fs* req)
{
    TruncateContext* ctx = (TruncateContext*)req;
    int result = (int)uv::fs_req_result(req);

    if (ctx.cb)
    {
        ctx.cb(result, ctx.user_data);
    }

    uv::fs_req_cleanup(req);
    free(ctx);
}

fn void on_fsync_internal(uv::Fs* req)
{
    FsyncContext* ctx = (FsyncContext*)req;
    int result = (int)uv::fs_req_result(req);

    if (ctx.cb)
    {
        ctx.cb(result, ctx.user_data);
    }

    uv::fs_req_cleanup(req);
    free(ctx);
}

fn void on_mkdir_internal(uv::Fs* req)
{
    MkdirContext* ctx = (MkdirContext*)req;
    int result = (int)uv::fs_req_result(req);

    if (ctx.cb)
    {
        ctx.cb(result, ctx.user_data);
    }

    uv::fs_req_cleanup(req);
    free(ctx);
}

<*
 Open a file asynchronously.

 @param loop : "Event loop"
 @param path : "File path"
 @param flags : "Open flags (OPEN_RDONLY, OPEN_WRONLY, OPEN_RDWR, etc.)"
 @param mode : "File permissions (e.g., 0644)"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void open(event_loop::EventLoop* loop, String path, int flags, int mode,
             OpenCallback callback, void* user_data) @public
{
    OpenContext* ctx = mem::new(OpenContext);
    ctx.cb = callback;
    ctx.user_data = user_data;
    ctx.loop = loop;

    ZString cpath = (ZString)path.ptr;
    int result = uv::fs_open(loop.loop, &ctx.req, cpath, flags, mode, &on_open_internal);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(null, result, user_data);
        }
        free(ctx);
    }
}

<*
 Read from a file asynchronously.

 @param offset : "File offset to read from"
 @param size : "Number of bytes to read"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void FileHandle.read(&self, long offset, usz size,
                        ReadCallback callback, void* user_data) @public
{
    ReadContext* ctx = mem::new(ReadContext);
    ctx.cb = callback;
    ctx.user_data = user_data;

    // Allocate buffer for reading
    ctx.buf.base = mem::new_array(char, size);
    ctx.buf.len = size;

    int result = uv::fs_read(self.loop.loop, &ctx.req, self.fd, &ctx.buf, 1, offset, &on_read_internal);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback({}, result, user_data);
        }
        free(ctx.buf.base);
        free(ctx);
    }
}

<*
 Write to a file asynchronously.

 @param offset : "File offset to write to"
 @param data : "Data to write"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void FileHandle.write(&self, long offset, char[] data,
                         WriteCallback callback, void* user_data) @public
{
    WriteContext* ctx = mem::new(WriteContext);
    ctx.cb = callback;
    ctx.user_data = user_data;

    ctx.buf.base = data.ptr;
    ctx.buf.len = data.len;

    int result = uv::fs_write(self.loop.loop, &ctx.req, self.fd, &ctx.buf, 1, offset, &on_write_internal);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(0, result, user_data);
        }
        free(ctx);
    }
}

<*
 Close a file asynchronously.

 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void FileHandle.close(&self, CloseCallback callback, void* user_data) @public
{
    CloseContext* ctx = mem::new(CloseContext);
    ctx.cb = callback;
    ctx.user_data = user_data;

    int result = uv::fs_close(self.loop.loop, &ctx.req, self.fd, &on_close_internal);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(result, user_data);
        }
        free(ctx);
    }

    // Free the FileHandle struct after initiating close
    // Note: The file descriptor will be closed by libuv asynchronously
    free(self);
}

<*
 Get file statistics asynchronously.

 @param loop : "Event loop"
 @param path : "File path"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void stat(event_loop::EventLoop* loop, String path,
             StatCallback callback, void* user_data) @public
{
    StatContext* ctx = mem::new(StatContext);
    ctx.cb = callback;
    ctx.user_data = user_data;

    ZString cpath = (ZString)path.ptr;
    int result = uv::fs_stat(loop.loop, &ctx.req, cpath, &on_stat_internal);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(null, result, user_data);
        }
        free(ctx);
    }
}

<*
 Truncate or extend a file asynchronously.

 Used for pre-allocating file space.

 @param size : "New file size"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void FileHandle.ftruncate(&self, long size,
                             TruncateCallback callback, void* user_data) @public
{
    TruncateContext* ctx = mem::new(TruncateContext);
    ctx.cb = callback;
    ctx.user_data = user_data;

    int result = uv::fs_ftruncate(self.loop.loop, &ctx.req, self.fd, size, &on_truncate_internal);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(result, user_data);
        }
        free(ctx);
    }
}

<*
 Sync file data to disk asynchronously.
 Ensures all written data is flushed from OS buffers to physical storage.

 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void FileHandle.fsync(&self, FsyncCallback callback, void* user_data) @public
{
    FsyncContext* ctx = mem::new(FsyncContext);
    ctx.cb = callback;
    ctx.user_data = user_data;

    int result = uv::fs_fsync(self.loop.loop, &ctx.req, self.fd, &on_fsync_internal);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(result, user_data);
        }
        free(ctx);
    }
}

<*
 Create a directory asynchronously.

 @param loop : "Event loop"
 @param path : "Directory path"
 @param mode : "Directory permissions (e.g., 0755)"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void mkdir(event_loop::EventLoop* loop, String path, int mode,
              MkdirCallback callback, void* user_data) @public
{
    MkdirContext* ctx = mem::new(MkdirContext);
    ctx.cb = callback;
    ctx.user_data = user_data;

    ZString cpath = (ZString)path.ptr;
    int result = uv::fs_mkdir(loop.loop, &ctx.req, cpath, mode, &on_mkdir_internal);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(result, user_data);
        }
        free(ctx);
    }
}
