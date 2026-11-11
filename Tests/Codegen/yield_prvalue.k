// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
// `yield` of a prvalue (a tuple literal, `i * i`), of a const
// value, or of an operand converted to the element type binds
// YieldPromise::yield_value's `T&` (not CL001E "cannot bind to a temporary").
// The operand is spilled to a frame local that outlives the suspension.

fn pairs(n: i32) -> yield (i32, i32) {
    for var i: i32 = 0; i < n; ++i {
        yield (i, i * 2)
    }
}

fn squares(n: i64) -> yield i64 {
    for var i: i64 = 1; i <= n; ++i {
        yield i * i
    }
}

fn widened() -> yield i64 {
    const k: i64 = 5
    yield k
    var small: i32 = 3
    yield small
}

fn main() -> i32 {
    var s: i32 = 0
    for p in pairs(3) {
        s += p.0 + p.1
    }

    var t: i64 = 0
    for v in squares(3) {
        t += v
    }

    for w in widened() {
        t += w
    }

    return s + (t as i32)
}
