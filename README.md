# c3io - Async I/O for C3

c3io wraps [libuv](https://libuv.org/) in C3 modules for non-blocking networking, file I/O and background
work. It suits programs that already run their own loop, such as games: poll it once per frame with
`run_nowait()` and nothing blocks.

## Modules

| Module | Purpose |
|---|---|
| `c3io::event_loop` | The loop: run modes, cancellation, non-blocking shutdown |
| `c3io::net` | `SocketAddr`: an IPv4 or IPv6 address and port, comparable and hashable |
| `c3io::udp` | UDP sockets: `try_send`, pooled `send`, connected sockets, broadcast |
| `c3io::tcp` | TCP clients and servers: `try_write`, pooled `write` |
| `c3io::file` | File operations, including `read_all` for loading a whole file |
| `c3io::fswatch` | File change notifications (`FileWatcher`) and stat polling (`FilePoller`) |
| `c3io::work` | Run functions on libuv's thread pool, with a completion on the loop thread |
| `c3io::dns` | Asynchronous name resolution |
| `c3io::timer` | One-shot and repeating timers |
| `c3io` | Error helpers (`last_status`, `error_name`, `error_message`) |
| `c3io::uv` | The raw libuv bindings the modules are built on |

## Requirements

- C3 compiler 0.8.4 or later
- libuv 1.x

Install libuv with your package manager:

```bash
sudo pacman -S libuv          # Arch Linux
sudo apt install libuv1-dev   # Debian/Ubuntu
sudo dnf install libuv-devel  # Fedora
brew install libuv            # macOS
vcpkg install libuv           # Windows
```

c3io runs on Linux, macOS and Windows; CI builds and tests all three.

## Using c3io in a project

The library is the `c3io.c3l` directory. Copy it (or add this repository as a submodule) under your
project's library folder and declare the dependency in `project.json`:

```json
{
  "dependency-search-paths": ["lib"],
  "dependencies": ["c3io"]
}
```

The library's `manifest.json` links libuv and, on Windows, the system libraries libuv needs. If libuv is
installed somewhere the linker doesn't search by default, add the directory with `-L`, for example
`c3c build -L /opt/homebrew/lib`.

## Example: a UDP game server

```c3
import c3io;
import c3io::event_loop;
import c3io::udp;
import c3io::net;
import std::collections::map;

HashMap{SocketAddr, int} players;

fn void on_packet(UdpSocket* socket, int status, char[] data, SocketAddr* from, bool truncated,
                  void* user_data)
{
    if (status != 0) return;
    if (!players.has_key(*from)) players.set(*from, (int)players.len());
    // data is only valid until this callback returns.
    (void)socket.try_send(from, "ack");
}

fn void main()
{
    EventLoop loop = event_loop::create()!!;
    players.init(mem);

    UdpSocket* socket = udp::create(&loop)!!;
    socket.bind(net::addr("::", 7777)!!)!!;  // IPv6 and, on dual-stack systems, IPv4
    socket.recv_start(&on_packet)!!;

    while (running())
    {
        loop.run_nowait();  // Handle whatever arrived; never blocks
        update_and_render();
    }

    while (!loop.shutdown()) {}  // Close everything; see "Shutting down"
    loop.free()!!;
}
```

`examples/` has a timer example and a minimal HTTP server; `test/` exercises every module.

## How c3io behaves

**Errors.** c3io never prints. A call that fails returns a fault, and `c3io::last_status()` gives the
libuv code behind it. Asynchronous callbacks receive the libuv code as `status`: 0 for success, negative
for an error. `c3io::error_name(code)` and `c3io::error_message(code)` turn a code into text. If an
operation can't be started, the call fails and its callback is never called.

**Allocators.** `event_loop::create(allocator)` sets the allocator for everything created on the loop.
Every `create()`, file call, resolver and work item also takes an optional allocator that overrides the
loop's, so a level or server session can use its own arena. libuv's own internal allocations still use
libc.

**Receive buffers.** Without an allocate callback, each UDP socket or TCP connection reads into one buffer
that it reuses, and the data passed to the callback is valid only until the callback returns. With an
allocate callback, the buffers are yours and c3io never frees them.

**Sending without allocating.** `UdpSocket.try_send` and `TcpConnection.try_write` hand data straight to
the kernel, with no allocation and no callback, and fail with `UDP_WOULD_BLOCK`/`TCP_WOULD_BLOCK` when
the kernel is busy. `send` and `write` copy the data and queue it; small messages reuse pooled memory, so
steady traffic stops allocating once the pool is warm.

**Threads.** Callbacks run on the loop thread, inside `run()`/`run_nowait()`. The one exception is the
work function passed to `work::queue`, which runs on a thread pool thread; its `after` callback runs on the
loop thread, which is where results such as GPU uploads belong. File operations and DNS queries also use
the thread pool, which has 4 threads unless `UV_THREADPOOL_SIZE` says otherwise.

**Cancelling.** File operations, work items and DNS queries return a `RequestId`. `loop.cancel(id)`
cancels one that hasn't started yet, and its callback then runs with `UV_ECANCELED`. Work that is already
running can't be interrupted.

**Shutting down.** `loop.shutdown()` cancels pending requests, closes every handle, runs a bounded number
of non-blocking iterations and returns whether the loop is done. If work is still running on the thread
pool it returns false; call it again on a later frame. `loop.free()` refuses, with
`EVENT_LOOP_STILL_ACTIVE`, until the loop is done.

## Building and testing

```bash
c3c build                  # builds the static library c3io.a
c3c test                   # runs the test suite
c3c test --sanitize=address
c3c build timer-example    # or http-server
```

## Changes

See [CHANGELOG.md](CHANGELOG.md).

## Authors

- Tristan Peralta <tristan@peralta.ph>
- Claude Code <noreply@anthropic.com>
