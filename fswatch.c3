module c3io::fswatch;

import c3io;
import c3io::uv;
import c3io::event_loop;

<*
 File watching
 =============
 FileWatcher reports changes to a file, or to the files in a directory, as
 the operating system announces them (inotify, FSEvents/kqueue,
 ReadDirectoryChangesW). It is the right choice for hot reload.

 FilePoller checks a path's stat at an interval instead. Use it where change
 notifications aren't available, such as some network filesystems.

 Usage:
   fn void on_change(FileWatcher* w, int status, String filename, WatchEvents events, void* data)
   {
       if (status == 0 && filename.ends_with(".png")) reload_texture(filename);
   }
   FileWatcher* watcher = fswatch::create(loop)!;
   watcher.start("assets/textures", &on_change, assets)!;

 Notes:
 - Editors often save by writing a temporary file and renaming it, so one
   save can arrive as several events, including renamed ones.
 - Recursive watching is only supported on macOS and Windows. On Linux,
   watch each directory separately.
*>

excuse
{
    WATCH_INIT_FAILED,
    WATCH_START_FAILED,
    WATCH_STOP_FAILED,
}

<*
 What happened to a watched entry.
*>
bitstruct WatchEvents : int
{
    bool renamed : 0;  // Created, deleted or renamed
    bool changed : 1;  // Contents or metadata changed
}

<*
 Called for each change. `filename` is the changed entry, relative to the
 watched directory (or the watched file's name); it can be empty when the
 system doesn't say, and is only valid during the callback. status is
 negative on a watch error.
*>
alias WatchCallback = fn void(FileWatcher* watcher, int status, String filename, WatchEvents events,
                              void* user_data);

<*
 Called when the polled path's stat changes. `prev` and `curr` are only
 valid during the callback. status is negative if the path can't be
 stat'ed, e.g. after it was deleted.
*>
alias PollCallback = fn void(FilePoller* poller, int status, uv::FileStat* prev, uv::FileStat* curr,
                             void* user_data);

struct FileWatcher
{
    event_loop::HandleOwner owner;
    Allocator allocator;
    uv::FsEvent* handle;
    event_loop::EventLoop* loop;
    WatchCallback callback;
    void* user_data;
}

struct FilePoller
{
    event_loop::HandleOwner owner;
    Allocator allocator;
    uv::FsPoll* handle;
    event_loop::EventLoop* loop;
    PollCallback callback;
    void* user_data;
}

fn void on_watcher_close(uv::Handle* handle) @private
{
    FileWatcher* watcher = uv::handle_get(FileWatcher, handle);
    Allocator allocator = watcher.allocator;
    alloc::free(allocator, handle);
    alloc::free(allocator, watcher);
}

fn void on_poller_close(uv::Handle* handle) @private
{
    FilePoller* poller = uv::handle_get(FilePoller, handle);
    Allocator allocator = poller.allocator;
    alloc::free(allocator, handle);
    alloc::free(allocator, poller);
}

fn void on_fs_event(uv::FsEvent* handle, ZString filename, int events, int status) @private
{
    FileWatcher* watcher = uv::handle_get(FileWatcher, handle);
    if (!watcher.callback) return;
    String name = filename ? filename.str_view() : "";
    watcher.callback(watcher, status, name, (WatchEvents)events, watcher.user_data);
}

fn void on_fs_poll(uv::FsPoll* handle, int status, uv::FileStat* prev, uv::FileStat* curr) @private
{
    FilePoller* poller = uv::handle_get(FilePoller, handle);
    if (poller.callback) poller.callback(poller, status, prev, curr, poller.user_data);
}

<*
 Create a file watcher.

 @param loop : "Event loop to attach to"
 @param allocator : "Allocator for the watcher (default: the loop's)"
*>
fn FileWatcher*? create(event_loop::EventLoop* loop, Allocator allocator = null)
{
    allocator = loop.allocator_or(allocator);
    uv::FsEvent* handle = c3io::alloc_handle(allocator, uv::FsEvent, uv::HandleType.FS_EVENT);
    int result = uv::fs_event_init(loop.loop, handle);
    if (result != 0)
    {
        alloc::free(allocator, handle);
        c3io::set_last_status(result);
        return WATCH_INIT_FAILED~;
    }

    FileWatcher* watcher = alloc::new(allocator, FileWatcher);
    watcher.owner.init(&on_watcher_close);
    watcher.allocator = allocator;
    watcher.handle = handle;
    watcher.loop = loop;
    uv::handle_set(handle, watcher);
    return watcher;
}

<*
 Start watching a file or directory.

 @param path : "File or directory to watch"
 @param callback : "Called for each change"
 @param user_data : "Passed to the callback"
 @param recursive : "Also watch subdirectories (macOS and Windows only)"
*>
fn void? FileWatcher.start(&self, String path, WatchCallback callback, void* user_data = null,
                           bool recursive = false)
{
    self.callback = callback;
    self.user_data = user_data;
    uint flags = recursive ? uv::UV_FS_EVENT_RECURSIVE : 0;
    int result;
    @pool()
    {
        result = uv::fs_event_start(self.handle, &on_fs_event, path.zstr_tcopy(), flags);
    };
    c3io::@check(result, WATCH_START_FAILED)!;
}

<*
 Stop watching. The watcher can be started again.
*>
fn void? FileWatcher.stop(&self)
{
    c3io::@check(uv::fs_event_stop(self.handle), WATCH_STOP_FAILED)!;
}

<*
 Stop watching and free the watcher. Don't use it afterwards.
*>
fn void FileWatcher.close(&self)
{
    uv::close((uv::Handle*)self.handle, &on_watcher_close);
}

<*
 Create a file poller.

 @param loop : "Event loop to attach to"
 @param allocator : "Allocator for the poller (default: the loop's)"
*>
fn FilePoller*? create_poller(event_loop::EventLoop* loop, Allocator allocator = null)
{
    allocator = loop.allocator_or(allocator);
    uv::FsPoll* handle = c3io::alloc_handle(allocator, uv::FsPoll, uv::HandleType.FS_POLL);
    int result = uv::fs_poll_init(loop.loop, handle);
    if (result != 0)
    {
        alloc::free(allocator, handle);
        c3io::set_last_status(result);
        return WATCH_INIT_FAILED~;
    }

    FilePoller* poller = alloc::new(allocator, FilePoller);
    poller.owner.init(&on_poller_close);
    poller.allocator = allocator;
    poller.handle = handle;
    poller.loop = loop;
    uv::handle_set(handle, poller);
    return poller;
}

<*
 Start polling a path.

 @param path : "File or directory to poll"
 @param interval_ms : "How often to check, in milliseconds"
 @param callback : "Called when the stat changes"
 @param user_data : "Passed to the callback"
*>
fn void? FilePoller.start(&self, String path, uint interval_ms, PollCallback callback,
                          void* user_data = null)
{
    self.callback = callback;
    self.user_data = user_data;
    int result;
    @pool()
    {
        result = uv::fs_poll_start(self.handle, &on_fs_poll, path.zstr_tcopy(), interval_ms);
    };
    c3io::@check(result, WATCH_START_FAILED)!;
}

<*
 Stop polling. The poller can be started again.
*>
fn void? FilePoller.stop(&self)
{
    c3io::@check(uv::fs_poll_stop(self.handle), WATCH_STOP_FAILED)!;
}

<*
 Stop polling and free the poller. Don't use it afterwards.
*>
fn void FilePoller.close(&self)
{
    uv::close((uv::Handle*)self.handle, &on_poller_close);
}
