module c3io::test_support;

import std::io::path;

<*
 A path in the system's temporary directory, allocated with the temp
 allocator.
*>
fn String temp_path(String name)
{
    return string::tformat("%s/c3io_%s", (String)path::temp_directory(tmem)!!, name);
}
