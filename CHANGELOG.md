# Changelog

## 0.3.0

Requires C3 0.8.4 or later. This release changes the API throughout.

### Breaking changes

- Modules are renamed from `async::*` to `c3io::*`, and the libuv bindings from `uv` to `c3io::uv`.
- The library sources live in `c3io.c3l/`; depend on the library `c3io` instead of listing source files.
- c3io no longer prints. Errors come back as faults, with the libuv code in `c3io::last_status()`.
- If an operation can't be started, the call returns a fault and its callback isn't called. File calls,
  `DnsResolver.resolve`/`resolve_tcp` and `work::queue` return a `RequestId?`.
- Addresses are `net::SocketAddr` values: `UdpSocket.bind`/`send`/`connect`, `tcp::connect` and
  `TcpConnection.bind` take a `SocketAddr` instead of an IP string and port. `UdpSocket.send_to` is
  replaced by `send`.
- UDP `RecvCallback` is `fn void(UdpSocket*, int status, char[] data, SocketAddr* from, bool truncated,
  void*)`. TCP `ReadCallback` is `fn void(TcpConnection*, int status, char[] data, void*)`, where
  status is `UV_EOF` at end of stream. `AcceptCallback` gains an `int status` before the client.
- `recv_start`/`read_start` take the receive callback first and the allocate callback last, as an
  optional argument. `TcpConnection.start_read`/`stop_read` are renamed `read_start`/`read_stop`.
- Buffers returned by an allocate callback are the caller's and are never freed by c3io.
- A connection whose connect fails is closed automatically.
- `EventLoop.free()` returns `void?` and refuses to free a loop that still has handles or requests;
  call `shutdown()` first. `close_all_handles()` is replaced by the non-blocking `shutdown()`.
- The work queue is `work::queue(loop, work, after, arg)`; `WorkContext` and
  `EventLoop.queue_work` are gone.
- `UdpSocket.bind`, `recv_start` and `Timer.start` return `void?`.
- Free a resolver with `DnsResolver.free()` instead of `free(resolver)`.

### Added

- `net::SocketAddr`, with IPv6 support everywhere an address is taken.
- `UdpSocket.try_send`, `TcpConnection.try_write`, and pooled `send`/`write`.
- `UdpSocket.connect`/`disconnect`, `set_broadcast`, send and receive buffer sizes, and
  `local_addr`/`peer_addr` on UDP sockets and TCP connections.
- An optional allocator on the loop and on everything created on it.
- `EventLoop.shutdown()` and `EventLoop.cancel(id)`.
- `file::read_all` and `FileHandle.read_into`.
- `c3io::fswatch`: `FileWatcher` and `FilePoller`.
- macOS, Windows and BSD struct layouts and constants, and CI on Linux, macOS and Windows.

### Fixed

- Strings passed to libuv are null-terminated; slices of longer strings were read past their end.
- A failed `tcp::connect` no longer leaves a freed handle in the loop.
- `run()` no longer reports a failure when the loop was stopped with `stop()`.
