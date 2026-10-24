// build: kairo F3-generic-instance-lifecycle-facts-unknown.k   (expect exit 0)
class <T> Box { pub var v: T }

// Box<i32> is trivially copyable, but its facts are read off the pattern
// Box<T>, where they are Unknown.
enum W { Has { b: Box<i32> }, Empty }

fn main() -> i32 {
    var w = W::Has { b: Box<i32>() }
    return 0
}
