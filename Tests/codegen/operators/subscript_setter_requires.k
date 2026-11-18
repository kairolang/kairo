// The two forms of `op []=` on one generic class, each under its own
// `requires` clause: the shape a map declares. The setter needs only a
// copyable key; the place form builds a default value, so it also needs
// `V impl Default`.
//
//   - `m[k] = v` runs the setter whether or not `V` has a default, and the
//     place form is never instantiated for a `V` without one.
//   - `m[k] += 1` and `m[k].n = 1` run the place form where `V` has a
//     default; where it has none they are SC153E, naming the clause that
//     does not hold.
//   - The value is passed by value: a move-only `V` is moved in, and a
//     later use of the moved variable is SC052E.
//   - `Slots`, with only the place form, stores a plain `x[k] = v` through
//     it.
// `Map` keeps what it was given in order, so `op []` reads the last entry.
// Each failing check returns its number.

interface Default {
    fn Default(self)
}

interface Copyable {
    @copy fn Copyable(self, const other: Self)
}

class Key impl Copyable {
    pub var n: i32
    fn Key(self, n: i32) { self.n = n }
    @copy fn Key(self, const other: Self) { self.n = other.n }
}

class Str {
    pub var n: i32 = 0
    fn Str(self, n: i32) { self.n = n }
    @move fn Str(self, other: Self) { self.n = other.n; other.n = 0 }
}

class Num impl Default {
    pub var n: i32
    fn Num(self) { self.n = 0 }
    fn Num(self, n: i32) { self.n = n }
}

class <K, V> Map {
    var keys: [K]
    var vals: [V]
    pub var places: i32 = 0
    pub var puts: i32 = 0
    fn Map(self) { }

    fn op [] (const self, const k: K) -> *const V {
        return &self.vals[self.vals.size() - 1]
    }

    fn op []= (self, const k: K, v: V) requires K impl Copyable {
        self.puts += 1
        self.keys.push(k)
        self.vals.push(v)
    }

    fn op []= (self, const k: K) -> *V requires K impl Copyable && V impl Default {
        self.places += 1
        if self.vals.size() == 0 {
            self.keys.push(k)
            self.vals.push(V())
        }

        return &self.vals[self.vals.size() - 1]
    }
}

class Slots {
    pub var d: [i32; 4]
    pub var places: i32 = 0
    fn Slots(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 {
        self.places += 1
        return &self.d[i]
    }
}

fn main() -> i32 {
    var ms = Map<Key, Str>()
    ms[Key(1)] = Str(10)
    var s = Str(20)
    ms[Key(2)] = s
    if ms.puts != 2 || ms.places != 0 || ms[Key(2)].n != 20 { return 1 }

    var mn = Map<Key, Num>()
    mn[Key(1)] = Num(5)
    mn[Key(1)].n += 2
    mn[Key(1)].n = mn[Key(1)].n + 1
    if mn.puts != 1 || mn.places != 2 || mn[Key(1)].n != 8 { return 2 }

    var sl = Slots()
    sl[1] = 4
    sl[1] += 1
    if sl.places != 2 || sl[1] != 5 { return 3 }
    return 0
}

eval if defined!(BAD) {
    fn no_default(m: *Map<Key, Str>) {
        (*m)[Key(1)].n += 1
        (*m)[Key(2)].n = 3
    }

    fn moved(m: *Map<Key, Str>) -> i32 {
        var s = Str(1)
        (*m)[Key(3)] = s
        return s.n
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: { %kairo %s --type-check-only -DBAD 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: subscript_setter_requires.k:105:{{[0-9]+}}: error [SC153E]: 'op []=' cannot be called on 'Map<Key, Str>': its 'requires' clause does not hold
// BAD-NEXT: note [SC153N]: 'Str' does not conform to 'Default'
// BAD: subscript_setter_requires.k:106:{{[0-9]+}}: error [SC153E]: 'op []=' cannot be called on 'Map<Key, Str>': its 'requires' clause does not hold
// BAD: subscript_setter_requires.k:112:16: error [SC052E]: 's' is used after being moved
// BAD-NEXT: subscript_setter_requires.k:111:{{[0-9]+}}: note [{{.*}}]: 's' was moved here, into a by-value parameter
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
