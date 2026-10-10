import c3io::event_loop;
import c3io::timer;
import std::io;

fn void on_timer(c3io::timer::Timer* timer, void* user_data)
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
    defer
    {
        while (!loop.shutdown()) {}
        loop.free()!!;
    }

    // Create a timer
    c3io::timer::Timer*? timer_opt = c3io::timer::create(&loop);
    if (catch err = timer_opt)
    {
        io::eprintfn("Failed to create timer");
        return 1;
    }
    c3io::timer::Timer* timer = timer_opt;

    // Start timer (1 second, non-repeating)
    timer.start(1000, 0, &on_timer, null)!!;

    // Run event loop until all handles are closed
    loop.run()!!;

    return 0;
}

