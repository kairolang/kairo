// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s --allow-empty
//
// `cxx::std::move(x)` of a move-only value lands in a by-value slot without
// a diagnostic: a tuple element of a Kairo class, a std::string, a by-value
// move-only C++ parameter (`consumeError(Error)`), and `push_back(T&&)` fed
// `move(*expected)` where operator* returns T&. (-c: these were
// reported against the self-host tree; they type clean, locked in here.)

ffi "c++" import "move_into_value_slots.h"
ffi "c++" import "utility"
ffi "c++" import "vector"
ffi "c++" import "string"

class Command {
    pub var v: i32 = 0
    fn Command(self) {}
    @move fn Command(self, other: Self) { self.v = other.v }
}
class Disp { pub var x: i32 = 0 }

fn pair() -> (Disp, Command) {
    var d = Disp()
    var c = Command()
    return (d, cxx::std::move(c))
}

fn with_string() -> (i32, cxx::std::string) {
    var s: cxx::std::string
    return (1, cxx::std::move(s))
}

fn by_value(err: Err) { consume(cxx::std::move(err)) }

fn into_vector() {
    var m: Exp<Mem>
    var members: cxx::std::vector<Mem>
    members.push_back(cxx::std::move(*m))
}

// CHECK-NOT: error
