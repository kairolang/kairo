// A generator meets an `I impl Iterator` bound through the generic
// `extend <T> Yield<T> impl Iterator`.

fn squares(n: i32) -> yield i32 {
    for var i = 0; i < n; i++ {
        yield i * i
    }
}

fn <I impl Iterator> count(it: I) -> i32 {
    var n = 0
    while true {
        var x = it.next()
        if !x? {
            break
        }

        n += 1
    }

    return n
}

fn main() -> i32 {
    return count(squares(3)) - 3
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
