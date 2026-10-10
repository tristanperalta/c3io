module c3io::file;

import c3io;
import c3io::uv;
import c3io::event_loop;

<*
 Async file I/O
 ==============
 File operations run on libuv's thread pool and report back through a
 callback on the loop thread. Each call returns a RequestId that
 EventLoop.cancel() accepts; a cancelled operation's callback gets
 UV_ECANCELED. If an operation can't be started, the call fails with a fault
 and the callback isn't called.

 Loading a whole file:
   fn void on_loaded(char[] data, int status, void* user_data)
   {
       if (status < 0) return;
       defer free(data);  // allocated with the allocator passed to read_all
       ...
   }
   file::read_all(loop, "textures/grass.png", &on_loaded, asset)!;

 Step by step:
   file::open(loop, "save.dat", OPEN_RDWR | OPEN_CREATE, 0o644, &on_open, user_data)!;
   // In on_open: file.write(0, data, &on_write, user_data)!;
   // When done:  file.close(&on_close, user_data)!;
*>

// File open flags: libuv's UV_FS_O_* values, which are the platform's
// O_* flags (the CRT's _O_* flags on Windows).
const int OPEN_RDONLY = 0x0000;
const int OPEN_WRONLY = 0x0001;
const int OPEN_RDWR   = 0x0002;
const int OPEN_CREATE = env::WIN32 ? 0x0100 : (env::DARWIN || env::BSD_FAMILY) ? 0x0200 : 0x0040;
const int OPEN_TRUNC  = env::WIN32 ? 0x0200 : (env::DARWIN || env::BSD_FAMILY) ? 0x0400 : 0x0200;
const int OPEN_APPEND = env::WIN32 ? 0x0008 : (env::DARWIN || env::BSD_FAMILY) ? 0x0008 : 0x0400;

excuse
{
    FILE_OPEN_FAILED,
    FILE_READ_FAILED,
    FILE_WRITE_FAILED,
    FILE_CLOSE_FAILED,
    FILE_STAT_FAILED,
    FILE_TRUNCATE_FAILED,
    FILE_SYNC_FAILED,
    DIR_CREATE_FAILED,
    DIR_SCAN_FAILED,
}

<*
 An open file. Created by open(), freed by close().
*>
struct FileHandle
{
    int fd;
    event_loop::EventLoop* loop;
    Allocator allocator;
}

// Directory entry (simplified from uv::Dirent)
struct DirEntry
{
    String name;
    uv::DirEntryType type;
}

// Callback types. `status` is 0 on success or a negative libuv error.
alias OpenCallback = fn void(FileHandle* file, int status, void* user_data);
alias ReadCallback = fn void(char[] data, int status, void* user_data);
alias WriteCallback = fn void(int bytes_written, int status, void* user_data);
alias CloseCallback = fn void(int status, void* user_data);
alias StatCallback = fn void(uv::FileStat* stat, int status, void* user_data);
alias TruncateCallback = fn void(int status, void* user_data);
alias FsyncCallback = fn void(int status, void* user_data);
alias MkdirCallback = fn void(int status, void* user_data);
alias ScandirCallback = fn void(DirEntry[] entries, int status, void* user_data);
alias ReadAllCallback = fn void(char[] data, int status, void* user_data);

<*
 Context of one file operation, allocated together with its uv request.
*>
struct FsContext @private
{
    event_loop::PendingRequest pending;
    event_loop::EventLoop* loop;
    Allocator allocator;
    void* callback;
    void* user_data;
    uv::Buf buf;
    bool owns_buffer;  // buf.base was allocated here and is freed after the callback
    uv::Fs* req;
}

fn FsContext* new_context(event_loop::EventLoop* loop, Allocator allocator, void* callback,
                          void* user_data) @private
{
    FsContext* ctx = c3io::alloc_with_req(allocator, FsContext, uv::ReqType.FS);
    ctx.loop = loop;
    ctx.allocator = allocator;
    ctx.callback = callback;
    ctx.user_data = user_data;
    return ctx;
}

<*
 Register a started operation, or clean up and fail if it didn't start.
*>
macro event_loop::RequestId? FsContext.submit(&self, int result, err)
{
    if (result < 0)
    {
        if (self.owns_buffer) alloc::free(self.allocator, self.buf.base);
        alloc::free(self.allocator, self);
        c3io::set_last_status(result);
        return err~;
    }
    return self.loop.track(&self.pending, self.req);
}

<*
 Take the result of a completed operation and untrack it. The context stays
 allocated until finish().
*>
fn int FsContext.complete(&self)
{
    self.loop.untrack(&self.pending);
    return (int)uv::fs_req_result(self.req);
}

fn void FsContext.finish(&self)
{
    uv::fs_req_cleanup(self.req);
    if (self.owns_buffer) alloc::free(self.allocator, self.buf.base);
    alloc::free(self.allocator, self);
}

macro int status_of(int result) @private => result < 0 ? result : 0;

fn void on_open_internal(uv::Fs* req) @private
{
    FsContext* ctx = uv::req_get(FsContext, req);
    int result = ctx.complete();
    FileHandle* file = null;
    if (result >= 0)
    {
        file = alloc::new(ctx.allocator, FileHandle);
        *file = { .fd = result, .loop = ctx.loop, .allocator = ctx.allocator };
    }
    OpenCallback cb = (OpenCallback)ctx.callback;
    if (cb) cb(file, status_of(result), ctx.user_data);
    ctx.finish();
}

fn void on_read_internal(uv::Fs* req) @private
{
    FsContext* ctx = uv::req_get(FsContext, req);
    int result = ctx.complete();
    char* base = (char*)ctx.buf.base;
    ReadCallback cb = (ReadCallback)ctx.callback;
    if (cb) cb(base[:result > 0 ? result : 0], status_of(result), ctx.user_data);
    ctx.finish();
}

fn void on_write_internal(uv::Fs* req) @private
{
    FsContext* ctx = uv::req_get(FsContext, req);
    int result = ctx.complete();
    WriteCallback cb = (WriteCallback)ctx.callback;
    if (cb) cb(result > 0 ? result : 0, status_of(result), ctx.user_data);
    ctx.finish();
}

fn void on_status_internal(uv::Fs* req) @private
{
    FsContext* ctx = uv::req_get(FsContext, req);
    int result = ctx.complete();
    CloseCallback cb = (CloseCallback)ctx.callback;  // Same shape as the other status-only callbacks
    if (cb) cb(status_of(result), ctx.user_data);
    ctx.finish();
}

fn void on_stat_internal(uv::Fs* req) @private
{
    FsContext* ctx = uv::req_get(FsContext, req);
    int result = ctx.complete();
    StatCallback cb = (StatCallback)ctx.callback;
    if (cb) cb(result >= 0 ? uv::fs_req_statbuf(req) : null, status_of(result), ctx.user_data);
    ctx.finish();
}

fn void on_scandir_internal(uv::Fs* req) @private
{
    FsContext* ctx = uv::req_get(FsContext, req);
    int result = ctx.complete();
    ScandirCallback cb = (ScandirCallback)ctx.callback;
    if (!cb)
    {
        ctx.finish();
        return;
    }

    DirEntry[] entries = {};
    if (result > 0)
    {
        entries = alloc::new_array(ctx.allocator, DirEntry, result);
        usz count = 0;
        uv::Dirent ent;
        while (count < entries.len && uv::fs_scandir_next(req, &ent) == 0)
        {
            entries[count++] = { ((ZString)ent.name).copy(ctx.allocator), ent.type };
        }
        entries = entries[:count];
    }
    cb(entries, status_of(result), ctx.user_data);

    foreach (entry : entries) alloc::free(ctx.allocator, entry.name.ptr);
    if (entries.ptr) alloc::free(ctx.allocator, entries.ptr);
    ctx.finish();
}

<*
 Open a file.

 @param loop : "Event loop"
 @param path : "File path"
 @param flags : "Open flags (OPEN_RDONLY, OPEN_WRONLY, OPEN_RDWR, etc.)"
 @param mode : "Permissions for a created file (e.g. 0o644)"
 @param callback : "Receives the FileHandle, which close() frees"
 @param user_data : "Passed to the callback"
 @param allocator : "Allocator for the request and the FileHandle (default: the loop's)"
*>
fn event_loop::RequestId? open(event_loop::EventLoop* loop, String path, int flags, int mode,
                               OpenCallback callback, void* user_data = null,
                               Allocator allocator = null)
{
    FsContext* ctx = new_context(loop, loop.allocator_or(allocator), (void*)callback, user_data);
    int result;
    @pool()
    {
        result = uv::fs_open(loop.loop, ctx.req, path.zstr_tcopy(), flags, mode, &on_open_internal);
    };
    return ctx.submit(result, FILE_OPEN_FAILED);
}

<*
 Read up to `size` bytes at `offset` into a buffer allocated for the
 operation. The data passed to the callback is freed when the callback
 returns; use read_into() to keep it.

 @param offset : "File offset to read from"
 @param size : "Maximum number of bytes to read"
 @param callback : "Receives the bytes read; fewer than size at end of file"
 @param user_data : "Passed to the callback"
*>
fn event_loop::RequestId? FileHandle.read(&self, long offset, usz size, ReadCallback callback,
                                          void* user_data = null)
{
    FsContext* ctx = new_context(self.loop, self.allocator, (void*)callback, user_data);
    ctx.buf = c3io::make_buf(alloc::malloc(self.allocator, (sz)size), size);
    ctx.owns_buffer = true;
    int result = uv::fs_read(self.loop.loop, ctx.req, self.fd, &ctx.buf, 1, offset, &on_read_internal);
    return ctx.submit(result, FILE_READ_FAILED);
}

<*
 Read into a buffer the caller owns. The buffer must stay valid until the
 callback runs; the callback's data is the filled part of it.

 @param offset : "File offset to read from"
 @param buffer : "Destination"
 @param callback : "Receives the filled part of buffer"
 @param user_data : "Passed to the callback"
*>
fn event_loop::RequestId? FileHandle.read_into(&self, long offset, char[] buffer, ReadCallback callback,
                                               void* user_data = null)
{
    FsContext* ctx = new_context(self.loop, self.allocator, (void*)callback, user_data);
    ctx.buf = c3io::make_buf(buffer.ptr, buffer.len);
    int result = uv::fs_read(self.loop.loop, ctx.req, self.fd, &ctx.buf, 1, offset, &on_read_internal);
    return ctx.submit(result, FILE_READ_FAILED);
}

<*
 Write at `offset`. The data isn't copied and must stay valid until the
 callback runs.

 @param offset : "File offset to write to"
 @param data : "Bytes to write"
 @param callback : "Receives the number of bytes written"
 @param user_data : "Passed to the callback"
*>
fn event_loop::RequestId? FileHandle.write(&self, long offset, char[] data, WriteCallback callback,
                                           void* user_data = null)
{
    FsContext* ctx = new_context(self.loop, self.allocator, (void*)callback, user_data);
    ctx.buf = c3io::make_buf(data.ptr, data.len);
    int result = uv::fs_write(self.loop.loop, ctx.req, self.fd, &ctx.buf, 1, offset, &on_write_internal);
    return ctx.submit(result, FILE_WRITE_FAILED);
}

<*
 Close the file and free the FileHandle. Don't use the handle afterwards,
 unless this fails, in which case the handle is still open.
*>
fn event_loop::RequestId? FileHandle.close(&self, CloseCallback callback = null, void* user_data = null)
{
    FsContext* ctx = new_context(self.loop, self.allocator, (void*)callback, user_data);
    int result = uv::fs_close(self.loop.loop, ctx.req, self.fd, &on_status_internal);
    event_loop::RequestId id = ctx.submit(result, FILE_CLOSE_FAILED)!;
    alloc::free(self.allocator, self);
    return id;
}

<*
 Truncate or extend the file, e.g. to pre-allocate space.
*>
fn event_loop::RequestId? FileHandle.ftruncate(&self, long size, TruncateCallback callback,
                                               void* user_data = null)
{
    FsContext* ctx = new_context(self.loop, self.allocator, (void*)callback, user_data);
    int result = uv::fs_ftruncate(self.loop.loop, ctx.req, self.fd, size, &on_status_internal);
    return ctx.submit(result, FILE_TRUNCATE_FAILED);
}

<*
 Flush the file's data to storage.
*>
fn event_loop::RequestId? FileHandle.fsync(&self, FsyncCallback callback, void* user_data = null)
{
    FsContext* ctx = new_context(self.loop, self.allocator, (void*)callback, user_data);
    int result = uv::fs_fsync(self.loop.loop, ctx.req, self.fd, &on_status_internal);
    return ctx.submit(result, FILE_SYNC_FAILED);
}

<*
 Get a file's statistics. The FileStat is only valid during the callback.

 @param allocator : "Allocator for the request (default: the loop's)"
*>
fn event_loop::RequestId? stat(event_loop::EventLoop* loop, String path, StatCallback callback,
                               void* user_data = null, Allocator allocator = null)
{
    FsContext* ctx = new_context(loop, loop.allocator_or(allocator), (void*)callback, user_data);
    int result;
    @pool()
    {
        result = uv::fs_stat(loop.loop, ctx.req, path.zstr_tcopy(), &on_stat_internal);
    };
    return ctx.submit(result, FILE_STAT_FAILED);
}

<*
 Create a directory.

 @param mode : "Permissions (e.g. 0o755)"
 @param allocator : "Allocator for the request (default: the loop's)"
*>
fn event_loop::RequestId? mkdir(event_loop::EventLoop* loop, String path, int mode, MkdirCallback callback,
                                void* user_data = null, Allocator allocator = null)
{
    FsContext* ctx = new_context(loop, loop.allocator_or(allocator), (void*)callback, user_data);
    int result;
    @pool()
    {
        result = uv::fs_mkdir(loop.loop, ctx.req, path.zstr_tcopy(), mode, &on_status_internal);
    };
    return ctx.submit(result, DIR_CREATE_FAILED);
}

<*
 List a directory's entries. The entries and their names are freed when the
 callback returns.

 @param allocator : "Allocator for the request and entries (default: the loop's)"
*>
fn event_loop::RequestId? scandir(event_loop::EventLoop* loop, String path, ScandirCallback callback,
                                  void* user_data = null, Allocator allocator = null)
{
    FsContext* ctx = new_context(loop, loop.allocator_or(allocator), (void*)callback, user_data);
    int result;
    @pool()
    {
        result = uv::fs_scandir(loop.loop, ctx.req, path.zstr_tcopy(), 0, &on_scandir_internal);
    };
    return ctx.submit(result, DIR_SCAN_FAILED);
}

// ============================================================================
// read_all: open, fstat, read, close as one operation
// ============================================================================

struct ReadAllContext @private
{
    event_loop::PendingRequest pending;
    event_loop::EventLoop* loop;
    Allocator allocator;       // For this context
    Allocator data_allocator;  // For the bytes handed to the caller
    ReadAllCallback cb;
    void* user_data;
    int fd;
    char[] data;
    usz filled;
    int status;  // First error; delivered after the file is closed
    uv::Buf buf;
    uv::Fs* req;
}

fn void ReadAllContext.deliver(&self)
{
    self.loop.untrack(&self.pending);
    char[] data = self.data[:self.filled];
    if (self.status < 0 && data.ptr)
    {
        alloc::free(self.data_allocator, data.ptr);
        data = {};
    }
    ReadAllCallback cb = self.cb;
    void* user_data = self.user_data;
    int status = self.status;
    alloc::free(self.allocator, self);
    if (cb) cb(data, status, user_data);
}

fn void ReadAllContext.fail_or_close(&self, int status)
{
    if (status < 0 && self.status == 0) self.status = status;
    if (self.fd < 0)
    {
        self.deliver();
        return;
    }
    if (uv::fs_close(self.loop.loop, self.req, self.fd, &read_all_on_close) < 0) self.deliver();
}

fn void ReadAllContext.read_next(&self)
{
    self.buf = c3io::make_buf(self.data.ptr + self.filled, self.data.len - self.filled);
    int result = uv::fs_read(self.loop.loop, self.req, self.fd, &self.buf, 1, (long)self.filled,
                             &read_all_on_read);
    if (result < 0) self.fail_or_close(result);
}

fn void read_all_on_open(uv::Fs* req) @private
{
    ReadAllContext* ctx = uv::req_get(ReadAllContext, req);
    int result = (int)uv::fs_req_result(req);
    uv::fs_req_cleanup(req);
    if (result < 0)
    {
        ctx.fail_or_close(result);
        return;
    }
    ctx.fd = result;
    result = uv::fs_fstat(ctx.loop.loop, req, ctx.fd, &read_all_on_fstat);
    if (result < 0) ctx.fail_or_close(result);
}

fn void read_all_on_fstat(uv::Fs* req) @private
{
    ReadAllContext* ctx = uv::req_get(ReadAllContext, req);
    int result = (int)uv::fs_req_result(req);
    ulong size = result >= 0 ? uv::fs_req_statbuf(req).st_size : 0;
    uv::fs_req_cleanup(req);
    if (result < 0 || size == 0)
    {
        ctx.fail_or_close(result);
        return;
    }
    ctx.data = alloc::new_array(ctx.data_allocator, char, (sz)size);
    ctx.read_next();
}

fn void read_all_on_read(uv::Fs* req) @private
{
    ReadAllContext* ctx = uv::req_get(ReadAllContext, req);
    int result = (int)uv::fs_req_result(req);
    uv::fs_req_cleanup(req);
    if (result <= 0)
    {
        // An error, or the file shrank since fstat: deliver what was read.
        ctx.fail_or_close(result);
        return;
    }
    ctx.filled += (usz)result;
    if (ctx.filled < ctx.data.len)
    {
        ctx.read_next();
        return;
    }
    ctx.fail_or_close(0);
}

fn void read_all_on_close(uv::Fs* req) @private
{
    // The file was opened read-only and the data is already read, so a failed
    // close doesn't affect the result.
    ReadAllContext* ctx = uv::req_get(ReadAllContext, req);
    uv::fs_req_cleanup(req);
    ctx.deliver();
}

<*
 Read a whole file in one call: open it, find its size, read it and close
 it. The callback receives all the bytes, allocated with `allocator`; the
 caller owns them and frees them with that allocator. On error the data is
 empty and nothing needs freeing.

 Cancelling stops the operation at its current step; the file is still
 closed before the callback runs with UV_ECANCELED.

 @param loop : "Event loop"
 @param path : "File to read"
 @param callback : "Receives the file's contents"
 @param user_data : "Passed to the callback"
 @param allocator : "Allocator for the returned data and the request (default: the loop's)"
*>
fn event_loop::RequestId? read_all(event_loop::EventLoop* loop, String path, ReadAllCallback callback,
                                   void* user_data = null, Allocator allocator = null)
{
    allocator = loop.allocator_or(allocator);
    ReadAllContext* ctx = c3io::alloc_with_req(allocator, ReadAllContext, uv::ReqType.FS);
    ctx.loop = loop;
    ctx.allocator = allocator;
    ctx.data_allocator = allocator;
    ctx.cb = callback;
    ctx.user_data = user_data;
    ctx.fd = -1;

    int result;
    @pool()
    {
        result = uv::fs_open(loop.loop, ctx.req, path.zstr_tcopy(), OPEN_RDONLY, 0, &read_all_on_open);
    };
    if (result < 0)
    {
        alloc::free(allocator, ctx);
        c3io::set_last_status(result);
        return FILE_READ_FAILED~;
    }
    return loop.track(&ctx.pending, ctx.req);
}
