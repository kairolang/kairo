// Use-after-move across control flow, for a MOVE value moved the ways a
// program moves one: into a C++ `T&&` (push_back), into a by-value
// parameter, into a variable, out of a field. `Str` stands in for a
// move-only string; Lib/builtin's string is COPY.
//
//   1. loops: a move reinitialized before the back edge is live next
//      iteration; one that is not, is moved there
//   2. a moving path that never reaches the use: return, break, continue
//      (with and without a reinit), __builtin_trap(), a `-> !` call. A
//      continue that moves without a reinit is read on the next iteration
//      on both arms of the `if`, and each arm is its own path, so each
//      reports
//   3. both arms move, both reinitialize: live after the join
//   4. `x = f(x)`: the argument moves before the store revives x
//   5. a move in the right operand of `&&`: the checker is path-
//      insensitive, so `name` is maybe-moved after the `if` and the use
//      under `!flag` is an error, by choice. Correlating the two
//      conditions is beyond a dataflow that does not track values.
//   6. partial moves: moving `p.a` leaves `p.b` readable; reassigning
//      `p.a` makes `p` whole again; a read of `p.a`, or of all of `p`,
//      while `p.a` is gone is an error

ffi "c++" import "vector"

class Str {
    pub var n: i32 = 0
    fn Str(self) { }
    fn Str(self, n: i32) { self.n = n }
    @move fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
}

class Pair { pub var a: Str  pub var b: Str }
struct Box { var s: Str }

fn count_words(s: Str) -> usize { return 11 }
fn print(s: *Str) { }
fn look(p: *Pair) { }
fn passthrough(s: Str) -> Str { return s }
fn fail() -> ! { __builtin_trap() }

// 1.
fn loop_reinit() -> i32 {
    var name = Str(1)
    var words: cxx::std::vector<Str>
    var i = 0
    while i < 3 {
        words.push_back(name)
        name = Str(2)
        i += 1
    }
    print(&name)
    return words.size() as i32
}

fn loop_no_reinit() {
    var name = Str(1)
    var words: cxx::std::vector<Str>
    var i = 0
    while i < 3 {
        words.push_back(name)
// DIAG: flow_scenarios.k:[[@LINE-1]]:25: error [SC052E]: 'name' is used after being moved
// DIAG: flow_scenarios.k:[[@LINE-2]]:25: note [{{[A-Z0-9]+}}]: 'name' was moved here, into a '@move' parameter
        i += 1
    }
}

fn loop_local() {
    var i = 0
    while i < 3 {
        var s = Str(i)
        count_words(s)
        i += 1
    }
}

// 2.
fn early_exit(flag: bool) -> i32 {
    var name = Str(1)
    var words: cxx::std::vector<Str>
    if flag {
        words.push_back(name)
        return 1
    }
    print(&name)
    return 0
}

fn early_break(flag: bool) {
    var name = Str(1)
    var words: cxx::std::vector<Str>
    var i = 0
    while i < 3 {
        if flag {
            words.push_back(name)
            break
        }
        print(&name)
        i += 1
    }
}

fn early_continue_reinit(flag: bool) {
    var name = Str(1)
    var words: cxx::std::vector<Str>
    var i = 0
    while i < 3 {
        i += 1
        if flag {
            words.push_back(name)
            name = Str(2)
            continue
        }
        print(&name)
    }
}

fn early_continue(flag: bool) {
    var name = Str(1)
    var words: cxx::std::vector<Str>
    var i = 0
    while i < 3 {
        i += 1
        if flag {
            words.push_back(name)
// DIAG: flow_scenarios.k:[[@LINE-1]]:29: error [SC052E]: 'name' is used after being moved
            continue
        }
        print(&name)
// DIAG: flow_scenarios.k:[[@LINE-1]]:16: error [SC052E]: 'name' is used after being moved
    }
}

fn early_trap(flag: bool) {
    var name = Str(1)
    var words: cxx::std::vector<Str>
    if flag {
        words.push_back(name)
        __builtin_trap()
    }
    print(&name)
}

fn early_noreturn(flag: bool) {
    var name = Str(1)
    if flag {
        count_words(name)
        fail()
    }
    print(&name)
}

// 3.
fn both_arms(flag: bool) {
    var name = Str(1)
    var words: cxx::std::vector<Str>
    if flag {
        words.push_back(name)
        name = Str(2)
    } else {
        count_words(name)
        name = Str(3)
    }
    print(&name)
}

fn one_arm(flag: bool) {
    var name = Str(1)
    if flag {
        count_words(name)
        name = Str(2)
    } else {
        count_words(name)
    }
    print(&name)
// DIAG: flow_scenarios.k:[[@LINE-1]]:12: error [SC052E]: 'name' is used after being moved
// DIAG: flow_scenarios.k:[[@LINE-4]]:21: note [{{[A-Z0-9]+}}]: 'name' was moved here, into a by-value parameter
}

// 4.
fn self_reassign() {
    var name = Str(1)
    name = passthrough(name)
    print(&name)
}

fn into_var() {
    var name = Str(1)
    var other = name
    print(&name)
// DIAG: flow_scenarios.k:[[@LINE-1]]:12: error [SC052E]: 'name' is used after being moved
// DIAG: flow_scenarios.k:[[@LINE-3]]:17: note [{{[A-Z0-9]+}}]: 'name' was moved here, into 'other'
}

fn into_literal() {
    var name = Str(1)
    var b = Box { s: name }
    print(&name)
// DIAG: flow_scenarios.k:[[@LINE-1]]:12: error [SC052E]: 'name' is used after being moved
// DIAG: flow_scenarios.k:[[@LINE-3]]:22: note [{{[A-Z0-9]+}}]: 'name' was moved here, into the field 's'
}

// 5.
fn short_circuit(flag: bool) {
    var name = Str(1)
    if flag && (count_words(name) > 0) { return }
    if !flag { print(&name) }
// DIAG: flow_scenarios.k:[[@LINE-1]]:23: error [SC052E]: 'name' is used after being moved
}

// 6.
fn partial() {
    var p = Pair()
    count_words(p.a)
    print(&p.b)
    p.a = Str(4)
    look(&p)
    count_words(p.a)
}

fn partial_twice() {
    var p = Pair()
    count_words(p.a)
    count_words(p.a)
// DIAG: flow_scenarios.k:[[@LINE-1]]:17: error [SC052E]: 'p.a' is used after being moved
// DIAG: flow_scenarios.k:[[@LINE-3]]:17: note [{{[A-Z0-9]+}}]: 'p.a' was moved here, into a by-value parameter
}

fn partial_whole() {
    var p = Pair()
    count_words(p.a)
    look(&p)
// DIAG: flow_scenarios.k:[[@LINE-1]]:11: error [SC052E]: 'p' is used after its part 'p.a' was moved
}

fn partial_whole_reassign() {
    var p = Pair()
    count_words(p.a)
    p = Pair()
    count_words(p.a)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
