module c3io::file;

import c3io;
import c3io::uv;
import c3io::event_loop;

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
excuse
{
    FILE_OPEN_FAILED,
    FILE_READ_FAILED,
    FILE_WRITE_FAILED,
    FILE_CLOSE_FAILED,
    FILE_STAT_FAILED,
    FILE_TRUNCATE_FAILED,
    DIR_CREATE_FAILED,
    DIR_SCAN_FAILED,
}

<*
 Verify at startup that the fixed uv::Fs opaque buffer is large enough for the
 runtime uv_fs_t size, so a future libuv growth fails loudly here instead of
 silently corrupting memory. uv::Fs must stay inline-sized because the *Context
 structs below embed it as their first field and recover the context by casting
 the request pointer.
*>
fn void check_fs_size() @init
{
    assert(uv::req_size(uv::ReqType.FS) <= uv::FS_OPAQUE_SIZE,
        "uv_fs_t exceeds the uv::Fs opaque buffer; increase uv::FS_OPAQUE_SIZE");
}

// File handle (wraps uv file descriptor and event loop)
struct FileHandle
{
    int fd;
    event_loop::EventLoop* loop;
    Allocator allocator;
}

// Backwards compatibility typedef
typedef File = int;

// Directory entry (simplified from uv::Dirent)
struct DirEntry
{
    String name;
    uv::DirEntryType type;
}

// Callback types
alias OpenCallback = fn void(FileHandle* file, int status, void* user_data);
alias ReadCallback = fn void(char[] data, int status, void* user_data);
alias WriteCallback = fn void(int bytes_written, int status, void* user_data);
alias CloseCallback = fn void(int status, void* user_data);
alias StatCallback = fn void(uv::FileStat* stat, int status, void* user_data);
alias TruncateCallback = fn void(int status, void* user_data);
alias FsyncCallback = fn void(int status, void* user_data);
alias MkdirCallback = fn void(int status, void* user_data);
alias ScandirCallback = fn void(DirEntry[] entries, int status, void* user_data);

// Request context structures
struct OpenContext
{
    uv::Fs req;
    Allocator allocator;
    OpenCallback cb;
    void* user_data;
    event_loop::EventLoop* loop;
}

struct ReadContext
{
    uv::Fs req;
    Allocator allocator;
    uv::Buf buf;
    ReadCallback cb;
    void* user_data;
}

struct WriteContext
{
    uv::Fs req;
    Allocator allocator;
    uv::Buf buf;
    WriteCallback cb;
    void* user_data;
}

struct CloseContext
{
    uv::Fs req;
    Allocator allocator;
    CloseCallback cb;
    void* user_data;
}

struct StatContext
{
    uv::Fs req;
    Allocator allocator;
    StatCallback cb;
    void* user_data;
}

struct TruncateContext
{
    uv::Fs req;
    Allocator allocator;
    TruncateCallback cb;
    void* user_data;
}

struct FsyncContext
{
    uv::Fs req;
    Allocator allocator;
    FsyncCallback cb;
    void* user_data;
}

struct MkdirContext
{
    uv::Fs req;
    Allocator allocator;
    MkdirCallback cb;
    void* user_data;
}

struct ScandirContext
{
    uv::Fs req;
    Allocator allocator;
    ScandirCallback cb;
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
            file = alloc::new(ctx.allocator, FileHandle);
            file.fd = result;
            file.loop = ctx.loop;
            file.allocator = ctx.allocator;
        }
        ctx.cb(file, result < 0 ? result : 0, ctx.user_data);
    }

    uv::fs_req_cleanup(req);
    alloc::free(ctx.allocator, ctx);
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
        alloc::free(ctx.allocator, ctx.buf.base);
    }

    uv::fs_req_cleanup(req);
    alloc::free(ctx.allocator, ctx);
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
    alloc::free(ctx.allocator, ctx);
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
    alloc::free(ctx.allocator, ctx);
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
    alloc::free(ctx.allocator, ctx);
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
    alloc::free(ctx.allocator, ctx);
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
    alloc::free(ctx.allocator, ctx);
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
    alloc::free(ctx.allocator, ctx);
}

fn void on_scandir_internal(uv::Fs* req)
{
    ScandirContext* ctx = (ScandirContext*)req;
    int result = (int)uv::fs_req_result(req);

    if (ctx.cb)
    {
        DirEntry[] entries = {};

        if (result >= 0)
        {
            // result contains the number of entries
            int num_entries = result;

            if (num_entries > 0)
            {
                // Allocate array for entries
                entries = alloc::new_array(ctx.allocator, DirEntry, num_entries);

                // Iterate through all entries
                int idx = 0;
                uv::Dirent ent;
                while (uv::fs_scandir_next(req, &ent) != uv::UV_EOF)
                {
                    if (idx < num_entries)
                    {
                        // Copy name (uv dirent name is a C string)
                        String name_str = ((ZString)ent.name).copy(ctx.allocator);
                        entries[idx].name = name_str;
                        entries[idx].type = ent.type;
                        idx++;
                    }
                }
            }
        }

        ctx.cb(entries, result < 0 ? result : 0, ctx.user_data);

        // Free entry names (user is responsible for freeing the entries array)
        for (usz i = 0; i < entries.len; i++)
        {
            alloc::free(ctx.allocator, entries[i].name.ptr);
        }
        if (entries.len > 0)
        {
            alloc::free(ctx.allocator, entries.ptr);
        }
    }

    uv::fs_req_cleanup(req);
    alloc::free(ctx.allocator, ctx);
}

<*
 Open a file asynchronously.

 @param loop : "Event loop"
 @param path : "File path"
 @param flags : "Open flags (OPEN_RDONLY, OPEN_WRONLY, OPEN_RDWR, etc.)"
 @param mode : "File permissions (e.g., 0644)"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
 @param allocator : "Allocator for the request and results (default: the loop's)"
*>
fn void open(event_loop::EventLoop* loop, String path, int flags, int mode,
             OpenCallback callback, void* user_data,
             Allocator allocator = null){
    allocator = loop.allocator_or(allocator);
    OpenContext* ctx = alloc::new(allocator, OpenContext);
    ctx.allocator = allocator;
    ctx.cb = callback;
    ctx.user_data = user_data;
    ctx.loop = loop;

    int result;
    @pool()
    {
        result = uv::fs_open(loop.loop, &ctx.req, path.zstr_tcopy(), flags, mode, &on_open_internal);
    };

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(null, result, user_data);
        }
        alloc::free(allocator, ctx);
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
                        ReadCallback callback, void* user_data){
    ReadContext* ctx = alloc::new(self.allocator, ReadContext);
    ctx.allocator = self.allocator;
    ctx.cb = callback;
    ctx.user_data = user_data;

    // Allocate buffer for reading
    ctx.buf.base = alloc::new_array(self.allocator, char, (sz)size);
    ctx.buf.len = size;

    int result = uv::fs_read(self.loop.loop, &ctx.req, self.fd, &ctx.buf, 1, offset, &on_read_internal);

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback({}, result, user_data);
        }
        alloc::free(self.allocator, ctx.buf.base);
        alloc::free(self.allocator, ctx);
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
                         WriteCallback callback, void* user_data){
    WriteContext* ctx = alloc::new(self.allocator, WriteContext);
    ctx.allocator = self.allocator;
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
        alloc::free(self.allocator, ctx);
    }
}

<*
 Close a file asynchronously.

 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void FileHandle.close(&self, CloseCallback callback, void* user_data){
    CloseContext* ctx = alloc::new(self.allocator, CloseContext);
    ctx.allocator = self.allocator;
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
        alloc::free(self.allocator, ctx);
    }

    // Free the FileHandle struct after initiating close
    // Note: The file descriptor will be closed by libuv asynchronously
    alloc::free(self.allocator, self);
}

<*
 Get file statistics asynchronously.

 @param loop : "Event loop"
 @param path : "File path"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
 @param allocator : "Allocator for the request and results (default: the loop's)"
*>
fn void stat(event_loop::EventLoop* loop, String path,
             StatCallback callback, void* user_data,
             Allocator allocator = null){
    allocator = loop.allocator_or(allocator);
    StatContext* ctx = alloc::new(allocator, StatContext);
    ctx.allocator = allocator;
    ctx.cb = callback;
    ctx.user_data = user_data;

    int result;
    @pool()
    {
        result = uv::fs_stat(loop.loop, &ctx.req, path.zstr_tcopy(), &on_stat_internal);
    };

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(null, result, user_data);
        }
        alloc::free(allocator, ctx);
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
                             TruncateCallback callback, void* user_data){
    TruncateContext* ctx = alloc::new(self.allocator, TruncateContext);
    ctx.allocator = self.allocator;
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
        alloc::free(self.allocator, ctx);
    }
}

<*
 Sync file data to disk asynchronously.
 Ensures all written data is flushed from OS buffers to physical storage.

 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
*>
fn void FileHandle.fsync(&self, FsyncCallback callback, void* user_data){
    FsyncContext* ctx = alloc::new(self.allocator, FsyncContext);
    ctx.allocator = self.allocator;
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
        alloc::free(self.allocator, ctx);
    }
}

<*
 Create a directory asynchronously.

 @param loop : "Event loop"
 @param path : "Directory path"
 @param mode : "Directory permissions (e.g., 0755)"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
 @param allocator : "Allocator for the request and results (default: the loop's)"
*>
fn void mkdir(event_loop::EventLoop* loop, String path, int mode,
              MkdirCallback callback, void* user_data,
             Allocator allocator = null){
    allocator = loop.allocator_or(allocator);
    MkdirContext* ctx = alloc::new(allocator, MkdirContext);
    ctx.allocator = allocator;
    ctx.cb = callback;
    ctx.user_data = user_data;

    int result;
    @pool()
    {
        result = uv::fs_mkdir(loop.loop, &ctx.req, path.zstr_tcopy(), mode, &on_mkdir_internal);
    };

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback(result, user_data);
        }
        alloc::free(allocator, ctx);
    }
}

<*
 Scan a directory asynchronously.

 Returns all directory entries (files and subdirectories) in a single callback.
 Entry names and the entries array are freed automatically after the callback returns.

 @param loop : "Event loop"
 @param path : "Directory path"
 @param callback : "Completion callback"
 @param user_data : "User data passed to callback"
 @param allocator : "Allocator for the request and results (default: the loop's)"
*>
fn void scandir(event_loop::EventLoop* loop, String path,
                ScandirCallback callback, void* user_data,
             Allocator allocator = null){
    allocator = loop.allocator_or(allocator);
    ScandirContext* ctx = alloc::new(allocator, ScandirContext);
    ctx.allocator = allocator;
    ctx.cb = callback;
    ctx.user_data = user_data;

    int result;
    @pool()
    {
        result = uv::fs_scandir(loop.loop, &ctx.req, path.zstr_tcopy(), 0, &on_scandir_internal);
    };

    if (result < 0)
    {
        // Immediate error
        if (callback)
        {
            callback({}, result, user_data);
        }
        alloc::free(allocator, ctx);
    }
}
