# c3io - Async I/O Library for C3

An async I/O library for C3 providing ergonomic wrappers around libuv for non-blocking network and file operations.

## Overview

c3io is a standalone library that provides high-level async I/O primitives built on top of libuv. It includes C3 bindings for libuv and offers an event-driven programming model with support for TCP, UDP, timers, DNS resolution, file operations, and work queue management.

## Features

### High-Level Async Modules

- **Event Loop** (`async::event_loop`) - Core event loop management
- **TCP** (`async::tcp`) - Async TCP client and server operations
- **UDP** (`async::udp`) - Async UDP socket operations
- **Timer** (`async::timer`) - One-shot and periodic timers
- **DNS** (`async::dns`) - Async DNS resolution
- **File** (`async::file`) - Async file I/O operations
- **Work Queue** (`async::work`) - Thread pool for CPU-intensive tasks

### Low-Level Bindings

- **libuv Bindings** (`uv`) - C3 bindings for libuv API

## Dependencies

- **libuv** - Cross-platform async I/O library
- **C3 compiler** - Version 0.6.x or later

### Installing libuv

**Arch Linux:**
```bash
sudo pacman -S libuv
```

**Ubuntu/Debian:**
```bash
sudo apt install libuv1-dev
```

**macOS:**
```bash
brew install libuv
```

**Fedora:**
```bash
sudo dnf install libuv-devel
```

## Building

```bash
c3c build
```

This will create `c3io.a` in the build directory.

## Testing

```bash
c3c test
```

The test suite includes 30 tests covering all async modules.

## Usage

### As a Git Submodule

Add c3io as a submodule to your project:

```bash
git submodule add https://github.com/YOUR_USERNAME/c3io.git lib/c3io
git submodule update --init --recursive
```

### As a Dependency

Add to your `project.json`:

```json
{
  "dependencies": ["c3io"],
  "dependency-search-paths": ["lib/c3io"]
}
```

### Example Code

Import the modules you need:

```c3
import async::event_loop;
import async::timer;
import std::io;

fn void on_timer(async::timer::Timer* timer, void* user_data)
{
    io::printfn("Timer fired!");
    timer.stop();
    timer.close();  // Clean up after firing
}

fn int main()
{
    // Create event loop
    event_loop::EventLoop? loop_opt = event_loop::create();
    if (catch err = loop_opt)
    {
        io::eprintfn("Failed to create event loop");
        return 1;
    }
    event_loop::EventLoop loop = loop_opt;
    defer loop.free();

    // Create a timer
    async::timer::Timer*? timer_opt = async::timer::create(&loop);
    if (catch err = timer_opt)
    {
        io::eprintfn("Failed to create timer");
        return 1;
    }
    async::timer::Timer* timer = timer_opt;

    // Start timer (1 second, non-repeating)
    timer.start(1000, 0, &on_timer, null);

    // Run event loop until all handles are closed
    loop.run()!!;

    return 0;
}
```

For more examples, see the `test/` directory.

## Authors

- Tristan Peralta <tristan@peralta.ph>
- Claude Code <noreply@anthropic.com>

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues.

### Platforms

Currently, c3io is primarily developed and tested on Linux. **We are actively looking for contributors to help with Windows and macOS support.**

If you have experience with:
- Windows async I/O (IOCP)
- macOS kqueue/Grand Central Dispatch
- Cross-platform testing and CI/CD

Please consider contributing! The library is built on libuv which already supports these platforms, so most of the work involves testing and ensuring the C3 bindings work correctly across all platforms.
