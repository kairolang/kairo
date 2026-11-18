// The setter form of `op []=` at run time: `fn op []= (self, k: K, v: V)`
// is the form a plain `x[k] = v` statement runs, and every other use runs
// the form it ran without a setter. Each form counts its calls, so each
// check sees which one ran; a failing check returns its number.
//
//   - `Two` (read form, place form, setter): the setter for `t[i] = v` and
//     `(t[i]) = v`; the place form for `+=`, `++`, `&t[i]`, `@inout`, and
//     an assignment whose result is read.
//   - `Cells`: a member written through and the container of a written
//     nested subscript take the place form; the inner store is a setter.
//   - `Mix`: no setter takes the index (`Key`), or the right side is an
//     anonymous initializer, which takes its type from the place: the
//     place form.
//   - `SetOnly` (read form and setter): stores and reads; a `for` loop's
//     update is a store too.
//   - `Table<V>`, a map whose place form inserts a default value and so
//     requires `V impl Default`: with `NoDef`, which has no default,
//     `t[k] = v` compiles and runs through the setter alone.
//   - The setter's own body stores through `self[k] = v` of a generic
//     class (`fill`).
//   - `Late`: both forms declared in the class and defined out of line,
//     and the setter called by name, `x.op []=(k, v)`.
//   - Evaluation order: receiver, index, value, then the setter; the place
//     form runs between the index and the value.

interface Default {
    fn Default(self)
}

class Two {
    pub var d: [i32; 4]
    pub var places: i32 = 0
    pub var puts: i32 = 0
    fn Two(self) { self.d = [1, 2, 3, 4] }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 {
        self.places += 1
        return &self.d[i]
    }

    fn op []= (self, const i: usize, v: i32) {
        self.puts += 1
        self.d[i] = v
    }
}

class Cell {
    pub var v: i32
    pub var puts: i32 = 0
    fn Cell(self) { self.v = 0 }
    fn op [] (const self, i: usize) -> i32 { return self.v }
    fn op []= (self, i: usize, x: i32) {
        self.puts += 1
        self.v = x
    }
}

class Cells {
    pub var d: [Cell; 2]
    pub var places: i32 = 0
    pub var puts: i32 = 0
    fn Cells(self) { }
    fn op [] (const self, i: usize) -> *const Cell { return &self.d[i] }
    fn op []= (self, i: usize) -> *Cell {
        self.places += 1
        return &self.d[i]
    }

    fn op []= (self, i: usize, c: Cell) {
        self.puts += 1
        self.d[i] = c
    }
}

struct Key {
    pub var n: i32 = 0
}

struct P {
    pub var x: i32 = 0
    pub var y: i32 = 0
}

class Mix {
    pub var d: [P; 2]
    pub var places: i32 = 0
    pub var puts: i32 = 0
    fn Mix(self) { }
    fn op [] (const self, i: usize) -> *const P { return &self.d[i] }
    fn op []= (self, i: usize) -> *P {
        self.places += 1
        return &self.d[i]
    }

    fn op []= (self, i: usize, v: P) {
        self.puts += 1
        self.d[i] = v
    }

    fn op [] (const self, k: Key) -> *const P { return &self.d[1] }
    fn op []= (self, k: Key) -> *P {
        self.places += 1
        return &self.d[1]
    }
}

class SetOnly {
    pub var d: [i32; 4]
    pub var puts: i32 = 0
    fn SetOnly(self) { self.d = [1, 2, 3, 4] }
    fn op [] (const self, i: usize) -> i32 { return self.d[i] }
    fn op []= (self, i: usize, v: i32) {
        self.puts += 1
        self.d[i] = v
    }
}

class NoDef {
    pub var n: i32
    fn NoDef(self, n: i32) { self.n = n }
}

class Num impl Default {
    pub var n: i32
    fn Num(self) { self.n = 0 }
    fn Num(self, n: i32) { self.n = n }
}

class <V> Table {
    var keys: [i32]
    var vals: [V]
    pub var inserts: i32 = 0
    pub var puts: i32 = 0
    fn Table(self) { }

    fn slot(const self, k: i32) -> usize {
        for var i: usize = 0; i < self.keys.size(); ++i {
            if self.keys[i] == k {
                return i
            }
        }

        return self.keys.size()
    }

    fn op [] (const self, k: i32) -> *const V {
        return &self.vals[self.slot(k)]
    }

    fn op []= (self, k: i32) -> *V requires V impl Default {
        var i = self.slot(k)
        if i == self.keys.size() {
            self.keys.push(k)
            self.vals.push(V())
            self.inserts += 1
        }

        return &self.vals[i]
    }

    fn op []= (self, const k: i32, v: V) {
        var i = self.slot(k)
        self.puts += 1
        if i == self.keys.size() {
            self.keys.push(k)
            self.vals.push(v)
            return
        }

        self.vals[i] = v
    }

    fn fill(self, k: i32, v: V) {
        self[k] = v
    }
}

class Late {
    pub var d: [i32; 4]
    pub var places: i32 = 0
    pub var puts: i32 = 0
    fn Late(self) { }
    fn op [] (const self, i: usize) -> *const i32
    fn op []= (self, i: usize) -> *i32
    fn op []= (self, i: usize, v: i32)
}

fn Late::op [] (const self, i: usize) -> *const i32 { return &self.d[i] }

fn Late::op []= (self, i: usize, v: i32) {
    self.puts += 1
    self.d[i] = v
}

fn Late::op []= (self, i: usize) -> *i32 {
    self.places += 1
    return &self.d[i]
}

var trace: i32 = 0

fn step(d: i32) -> i32 {
    trace = trace * 10 + d
    return d
}

class Ord {
    pub var d: [i32; 4]
    fn Ord(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize, v: i32) {
        step(4)
        self.d[i] = v
    }
}

class OrdPlace {
    pub var d: [i32; 4]
    fn OrdPlace(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 {
        step(4)
        return &self.d[i]
    }
}

var ord: Ord = Ord()
var ord_place: OrdPlace = OrdPlace()

fn the_ord() -> *Ord {
    step(1)
    return &ord
}

fn the_ord_place() -> *OrdPlace {
    step(1)
    return &ord_place
}

fn bump(@inout x: i32) {
    x += 100
}

fn main() -> i32 {
    var t = Two()
    t[0] = 9
    if t.puts != 1 || t.places != 0 || t[0] != 9 { return 1 }
    (t[1]) = 8
    if t.puts != 2 || t.places != 0 || t[1] != 8 { return 2 }
    t[1] += 1
    if t.puts != 2 || t.places != 1 || t[1] != 9 { return 3 }
    ++t[2]
    if t.puts != 2 || t.places != 2 || t[2] != 4 { return 4 }
    bump(&t[3])
    if t.puts != 2 || t.places != 3 || t[3] != 104 { return 5 }
    var *p = &t[0]
    *p = 6
    if t.puts != 2 || t.places != 4 || t[0] != 6 { return 6 }
    var y = (t[1] = 5)
    if t.puts != 2 || t.places != 5 || y != 5 || t[1] != 5 { return 7 }

    var cs = Cells()
    cs[0].v = 3
    if cs.puts != 0 || cs.places != 1 || cs[0].v != 3 { return 8 }
    cs[1][0] = 4
    if cs.puts != 0 || cs.places != 2 || cs.d[1].puts != 1 || cs[1].v != 4 { return 9 }
    cs[0] = Cell()
    if cs.puts != 1 || cs.places != 2 || cs[0].v != 0 { return 10 }

    var m = Mix()
    m[0] = P { x: 1, y: 2 }
    if m.puts != 1 || m.places != 0 || m[0].y != 2 { return 11 }
    m[Key()] = P { x: 3, y: 4 }
    if m.puts != 1 || m.places != 1 || m[1].y != 4 { return 12 }
    m[0] = {.x: 5, .y: 6}
    if m.puts != 1 || m.places != 2 || m[0].y != 6 { return 13 }

    var s = SetOnly()
    s[2] = 7
    if s.puts != 1 || s[2] != 7 { return 14 }
    for var i: usize = 0; i < 2; s[i] = 9 { ++i }
    if s.puts != 3 || s[1] != 9 || s[2] != 9 { return 20 }

    var nd = Table<NoDef>()
    nd[7] = NoDef(70)
    nd[8] = NoDef(80)
    nd[7] = NoDef(71)
    nd.fill(9, NoDef(90))
    if nd.puts != 4 || nd.inserts != 0 { return 15 }
    if nd[7].n != 71 || nd[8].n != 80 || nd[9].n != 90 { return 16 }

    var nm = Table<Num>()
    nm[1] = Num(5)
    nm[1].n += 2
    nm[2].n = 9
    if nm.puts != 1 || nm.inserts != 1 || nm[1].n != 7 || nm[2].n != 9 { return 17 }

    var late = Late()
    late[0] = 3
    late[0] += 1
    late.op []=(1, 8)
    if late.puts != 2 || late.places != 1 || late[0] != 4 || late[1] != 8 { return 21 }

    trace = 0
    (*the_ord())[step(2) as usize] = step(3)
    if trace != 1234 || ord[2] != 3 { return 18 }
    trace = 0
    (*the_ord_place())[step(2) as usize] = step(3)
    if trace != 1243 || ord_place[2] != 3 { return 19 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
