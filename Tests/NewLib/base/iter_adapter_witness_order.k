// An adapter whose associated type is its parameter's (`type Item =
// I::Item`) has one full witness specialization per instance. Its inline
// forwarder calls the extension member at the instance's argument, and C++
// checks that call's bound where the forwarder is written, so the
// specialization that makes the argument conform is emitted first: here the
// partial one of `Yield<T>`, and the full one of the inner adapter.

class <I impl Iterator> Pass {
    pub var it: I
}

extend <I impl Iterator> Pass<I> impl Iterator {
    type Item = I::Item
    fn next(self) -> I::Item? {
        return self.it.next()
    }
}

fn <I impl Iterator> total(it: I) -> i32 requires __builtin_is_same<I::Item, i32>() {
    var t = 0
    loop {
        var x = it.next()
        if !x? {
            break
        }

        t += unwrap!(x)
    }

    return t
}

fn upto(n: i32) -> yield i32 {
    for var i = 0; i < n; i++ {
        yield i
    }
}

fn main() -> i32 {
    var one = total(Pass<Yield<i32>> { it: upto(4) })
    var two = total(Pass<Pass<Yield<i32>>> { it: Pass<Yield<i32>> { it: upto(5) } })
    return (one - 6) + (two - 10)
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
