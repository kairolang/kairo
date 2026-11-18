// An assignment evaluates its target first, then the value, then stores
// (operators.mdx, "Evaluation order"). C++17 runs the right side of `=` and
// `op=` first, so a target with an effect is bound before the value is read
// whenever the value is not a constant, a plain local included: `arr[p++] = p`
// stores the incremented `p`. Covers a subscript, a dereference, a field
// through a call, a compound assignment, a class's `op []=` place form, a
// vector element and a method call that writes its receiver, each at -O0 and
// -O2.
import std::io

var trace: i32 = 0

fn note(d: i32) -> i32 {
    trace = trace * 10 + d
    return d
}

class Cell {
    var x: i32 = 0
}

var cell: Cell = Cell()
var slot: i32 = 0

fn next() -> *i32 {
    note(1)
    return &slot
}

fn cur() -> i32 { return note(2) * 0 + slot + 40 }

fn holder() -> *Cell {
    note(3)
    return &cell
}

class Ctr {
    var n: i32 = 0
    fn bump(self) -> usize {
        self.n += 1
        return 0
    }
}

class Map {
    var d: [i32; 4] = [0, 0, 0, 0]
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
}

fn key() -> usize {
    note(4)
    return 2
}

fn val() -> i32 { return note(5) }

fn main() -> i32 {
    var arr: [i32; 4] = [9, 9, 9, 9]
    var p = 0
    arr[p++] = p
    io::println(f"arr[p++] = p: {arr[0]} {arr[1]} p={p}")

    var i = 1
    arr[i++] = i
    io::println(f"arr[i++] = i: {arr[1]} {arr[2]} i={i}")

    trace = 0
    arr[note(1)] = note(2)
    io::println(f"arr[f()] = g(): trace={trace} arr1={arr[1]}")

    trace = 0
    slot = 1
    *next() = cur()
    io::println(f"*next() = cur(): trace={trace} slot={slot}")

    trace = 0
    var z = 7
    holder()->x = z
    io::println(f"holder()->x = z: trace={trace} x={cell.x}")

    var b: [i32; 4] = [10, 20, 30, 40]
    var j = 0
    b[j++] += j
    io::println(f"b[j++] += j: {b[0]} {b[1]} j={j}")

    var k = 1
    b[k++] |= k
    io::println(f"b[k++] |= k: {b[1]} k={k}")

    trace = 0
    var m = Map()
    m[key()] = val()
    io::println(f"m[k()] = v(): trace={trace} m2={m.d[2]}")

    var q = 3
    m[(q++) as usize] = q
    io::println(f"m[q++] = q: m3={m.d[3]} q={q}")

    var v: [i32] = [5, 5, 5]
    var w: usize = 0
    v[w++] = w as i32
    io::println(f"v[w++] = w: {v[0]} {v[1]} w={w}")

    var r: [i32; 2] = [9, 9]
    var c = Ctr()
    r[c.bump()] = c.n
    io::println(f"r[c.bump()] = c.n: {r[0]} n={c.n}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT: arr[p++] = p: 1 9 p=1
// OUT-NEXT: arr[i++] = i: 2 9 i=2
// OUT-NEXT: arr[f()] = g(): trace=12 arr1=2
// OUT-NEXT: *next() = cur(): trace=12 slot=41
// OUT-NEXT: holder()->x = z: trace=3 x=7
// OUT-NEXT: b[j++] += j: 11 20 j=1
// OUT-NEXT: b[k++] |= k: 22 k=2
// OUT-NEXT: m[k()] = v(): trace=45 m2=5
// OUT-NEXT: m[q++] = q: m3=4 q=4
// OUT-NEXT: v[w++] = w: 1 5 w=1
// OUT-NEXT: r[c.bump()] = c.n: 1 n=1
