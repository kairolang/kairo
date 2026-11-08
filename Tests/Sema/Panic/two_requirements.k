// A method that meets two panicking requirements -- two interfaces, or an
// override that is also a conformer -- whose panic sets differ (P174). C++
// gets ONE return type for it, the first requirement's panic result, and
// the other's witness (or the vtable) names its own: before, that failed in
// C++ ("no viable conversion from 'Panic<int, Missing>' to 'Panic<int,
// Closed>'"). Until a per-requirement thunk exists it is SC116E, at the
// method, with a note at each requirement. Equal sets form one result and
// are accepted, in whatever order they are written. A method meeting two
// is also held to EACH requirement's set (before, only the first).
struct Missing { var n: i32 }
struct Closed {}

interface Source {
    fn read(self, n: i32) panic(Missing) -> i32
}
interface Stream {
    fn read(self, n: i32) panic(Closed) -> i32
}
interface Both {
    fn read(self, n: i32) panic(Closed, Missing) -> i32
}
interface Again {
    fn read(self, n: i32) panic(Missing, Closed) -> i32
}

// Two interfaces, two sets: reported.
class File impl Source, Stream {
    fn read(self, n: i32) -> i32 { return n }
}

// Two interfaces, one set written in two orders: fine.
class Pipe impl Both, Again {
    fn read(self, n: i32) panic -> i32 {
        if n < 0 { panic Closed {} }
        return n
    }
}

// An override whose base's set is not its requirement's: reported.
class Base {
    virtual fn read(self, n: i32) panic(Missing) -> i32 { return n }
}
class Sub derives Base impl Stream {
    override fn read(self, n: i32) -> i32 { return n + 1 }
}

// Held to the second requirement too: 'Missing' is not in Stream's set.
class Disk impl Source, Stream {
    fn read(self, n: i32) panic -> i32 {
        if n < 0 { panic Missing { n: n } }
        return n
    }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: two_requirements.k:28:8: error [SC116E]: a method meeting both 'Source::read' and 'Stream::read', whose panic sets differ, is not yet supported
// CHECK-NEXT: two_requirements.k:14:5: note [SC116N]: 'Source::read' panics with 'Missing'
// CHECK-NEXT: two_requirements.k:17:5: note [SC116N]: 'Stream::read' panics with 'Closed'
// CHECK: two_requirements.k:44:17: error [SC116E]: a method meeting both 'Base::read' and 'Stream::read', whose panic sets differ, is not yet supported
// CHECK-NEXT: two_requirements.k:41:5: note [SC116N]: 'Base::read' panics with 'Missing'
// CHECK-NEXT: two_requirements.k:17:5: note [SC116N]: 'Stream::read' panics with 'Closed'
// CHECK: two_requirements.k:49:8: error [SC116E]: a method meeting both 'Source::read' and 'Stream::read', whose panic sets differ, is not yet supported
// CHECK: two_requirements.k:49:27: error [SC208E]: 'Missing' is not in the panic set of 'Stream::read', which this implements; a conforming method's set must be a subset of it
