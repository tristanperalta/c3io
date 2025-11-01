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

