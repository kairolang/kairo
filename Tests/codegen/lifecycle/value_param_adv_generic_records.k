// Covers by-value parameters typed by the generic parameter of the enclosing class or
// extend block, instantiated with a destructive class, containers, a string and
// a COPY class, plus a user generic stack that holds itself through a node.
import std::io::println
var made: i32 = 0
var released: i32 = 0
var fails: i32 = 0
class R {
    var id: i32 = 0
    fn R(self, id: i32) { self.id = id; made += 1 }
    @move fn R(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) {
        if self.id != 0 { released += 1; self.id = 0 }
    }
}
fn chk(const name: string) {
    if made != released { println(f"FAIL {name}: made {made} released {released}"); fails += 1 }
    made = 0
    released = 0
}
fn mkr(i: i32) -> R { return R(i) }
fn sink(r: R) { }
fn rd(r: R) -> i32 { return r.id }
class <T> Box {
    var v: T
    fn Box(self, x: T) { self.v = x }
    @move fn Box(self, o: Self) { self.v = o.v }
    fn put(self, x: T) { self.v = x }
    fn eat(self, x: T) { }
    fn swap(self, x: T) -> T { var old = self.v; self.v = x; return old }
    static fn mk(x: T) -> Box<T> { return Box<T>(x) }
}
extend <T> Box<T> {
    fn put2(self, x: T, y: T) { self.v = y }
    fn id(self, x: T) -> T { return x }
    fn cond(self, x: T, b: bool) { if b { self.v = x } }
}
class <T> Stack {
    var items: [T]
    fn Stack(self) { }
    @move fn Stack(self, o: Self) { self.items = o.items }
    fn put(self, v: T) { self.items.push(v) }
}
class Node {
    var id: i32 = 0
    var kids: Stack<Node>
    fn Node(self, i: i32) { self.id = i }
    @move fn Node(self, o: Self) { self.id = o.id; self.kids = o.kids }
    fn add(self, n: Node) { self.kids.put(n) }
}
class Plain { var n: i32 = 0
    fn Plain(self, n: i32) { self.n = n } }
class Cp { var n: i32 = 0
    fn Cp(self, n: i32) { self.n = n }
    @copy fn Cp(self, const o: Self) { self.n = o.n }
    fn op finally(self) { }
}
fn pbox(b: Box<R>) -> i32 { return b.v.id }
fn mbox(b: Box<R>) -> Box<R> { return b }

fn main() -> i32 {
    made = 0
    { var b = Box<R>(R(1)); b.put(R(2)) } chk("b1")
    { var b = Box<R>(R(1)); var a = R(2); b.put(a) } chk("b2")
    { var b = Box<R>(R(1)); var a = R(2); b.eat(a) } chk("b3")
    { var b = Box<R>(R(1)); var a = R(2); var o = b.swap(a) } chk("b4")
    { var b = Box<R>(R(1)); var a = R(2); var c = R(3); b.put2(a, c) } chk("b5")
    { var b = Box<R>(R(1)); var a = R(2); var o = b.id(a) } chk("b6")
    { var b = Box<R>(R(1)); var a = R(2); b.cond(a, true) } chk("b7")
    { var b = Box<R>(R(1)); var a = R(2); b.cond(a, false) } chk("b8")
    { var a = R(2); var b = Box<R>::mk(a) } chk("b9")
    { var b = Box<R>(R(1)); var a = R(2); b.v = b.id(a) } chk("b10")
    { var b = Box<R>(R(1)); var o = pbox(b) } chk("b11")
    { var b = Box<R>(R(1)); var o = mbox(b) } chk("b12")
    { var b = Box<R>(R(1)); b = mbox(b) } chk("b13")
    { var a = R(2); var b = Box<R>(a); var c = Box<Box<R>>(b) } chk("b14")
    { var b = Box<Box<R>>(Box<R>(R(1))); var a = Box<R>(R(2)); b.put(a); var x = Box<R>(R(3)); b.cond(x, true) } chk("b15")
    { var b = Box<string>("x"); var s = "hello"; b.put(s) b.cond("zz", true) } chk("b16")
    { var b = Box<i32>(1); b.put(2); var c = Box<[R]>([R(1)]); var v: [R] = [R(2), R(3)]; c.put(v); var w: [R] = [R(4)]; c.cond(w, false) } chk("b17")
    { var b = Box<Cp>(Cp(1)); var c = Cp(2); b.put(c); b.cond(c, true); var d = c }  chk("b18")
    { var b = Box<Plain>(Plain(1)); var c = Plain(2); b.put(c); b.cond(c, true) } chk("b19")
    { var b = Box<R>(R(1)); var a = R(2); b.v = b.swap(a) } chk("b20")
    { var b = Box<R>(R(1)); b.put(b.swap(R(3))) } chk("b21")
    { var s = Stack<R>(); var a = R(1); s.put(a); s.put(R(2)) } chk("s1")
    { var n = Node(1); n.add(Node(2)); var m = Node(3); n.add(m) } chk("n1")
    println(f"fails {fails}")
    return fails
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d
// RUN: rm -f %t.exe %t.off.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.off.exe | %FileCheck %s --match-full-lines
// CHECK-NOT: FAIL
// CHECK: fails 0
