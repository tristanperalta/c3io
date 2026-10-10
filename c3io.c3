module c3io;

import c3io::uv;

<*
 Shared helpers for the c3io modules: libuv status reporting and allocation
 of libuv handles and requests.

 c3io never prints. Synchronous calls that fail return a fault and record the
 libuv status code, which `last_status()` returns. Asynchronous callbacks
 receive the libuv status code directly. Turn a code into text with
 `error_name()` or `error_message()`.
*>

tlocal int last_status_code;

<*
 The libuv status code recorded by the most recent c3io call that failed on
 this thread. 0 if no call has failed yet.
*>
fn int last_status() => last_status_code;

<*
 The libuv name of a status code, e.g. "EADDRINUSE".
*>
fn String error_name(int code) => ((ZString)uv::err_name(code)).str_view();

<*
 A human-readable description of a libuv status code.
*>
fn String error_message(int code) => ((ZString)uv::strerror(code)).str_view();

<*
 Record `result` and return `err` if it is a libuv error (negative).

 @param result : "Return value of a libuv call"
 @param err : "Fault to return on error"
*>
macro void? @check(int result, err)
{
    if (result < 0)
    {
        last_status_code = result;
        return err~;
    }
}

<*
 Record `result` as the last status code.
*>
fn void set_last_status(int result) => last_status_code = result;

<*
 Allocate zeroed memory for a libuv handle of the given type.
*>
macro alloc_handle($Type, uv::HandleType type)
{
    return ($Type*)mem::calloc((sz)uv::handle_size(type));
}

<*
 Allocate memory for a libuv request of the given type.
*>
macro alloc_req($Type, uv::ReqType type)
{
    return ($Type*)mem::calloc((sz)uv::req_size(type));
}
