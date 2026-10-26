// passthrough.k
ffi "c++" import "thrower.hh"

// `@unwind`: without it the frame is noexcept and the throw terminates.
@unwind pub fn pass_through(x: i32) -> i32 {
    return checked_double(x) + 1             // no try: exception must unwind through this frame
}
