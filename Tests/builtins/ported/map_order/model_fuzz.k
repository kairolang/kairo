// Randomized check of HashMap<u64, u64>, HashSet<u64> and a HashMap whose key
// hashes to sixteen values, against a model that keeps its entries in two
// vectors, in order, and applies the documented ordering rule of each
// operation: a new key appends, a present key keeps its place, swap_remove
// moves the last entry into the gap, shift_remove closes it, pop takes the
// last, retain keeps the survivors in order, merge and the set operators
// append the other side's new entries in its order, clear empties. A fixed
// seed drives 200000 operations on the map, 200000 on the set and 100000 on
// the colliding map, over key spaces of 16 to 4000 keys that change every
// 10000 operations (alternating phases that remove and phases that mostly
// add, so the tables grow through several sizes). Every operation's return
// value is checked against the model; the whole order (keys and values, by
// the pair loop and by the entries or items slice) is compared every 16
// operations and after every whole-table operation. A failure prints the
// stream, the operation number and the operation.
//
// Cases from indexmap tests/quick.rs (operations_i8, operations_string, keys_values, keys_values_mut, insert_remove, retain_ordered, equality, pop, shift_remove)
// Cases from indexmap src/map/tests.rs and src/set/tests.rs (insert_order, swap_remove_index, remove)

import std::io

var checks: u64 = 0
var failures: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

class Rng {
    var s: u64
    pub fn Rng(self, seed: u64) { self.s = seed * 0x9E3779B97F4A7C15 + 0x2545F4914F6CDD1D }
    pub fn next(self) -> u64 {
        self.s ^= self.s << 13
        self.s ^= self.s >> 7
        self.s ^= self.s << 17
        return self.s
    }
    pub fn below(self, n: u64) -> u64 { return self.next() % n }
}

/// The reference: keys and values in order.
class Model {
    pub var keys: [u64]
    pub var vals: [u64]

    pub fn find(self, k: u64) -> isize {
        for var i: usize = 0; i < self.keys.size(); i += 1 {
            if self.keys[i] == k { return i as isize }
        }
        return -1
    }

    /// Sets, or appends; returns the old value when the key was there.
    pub fn put(self, k: u64, v: u64) -> u64? {
        var i = self.find(k)
        if i >= 0 {
            var old = self.vals[i as usize]
            self.vals[i as usize] = v
            return old
        }
        self.keys.push(k)
        self.vals.push(v)
        return null
    }

    pub fn swap_remove(self, k: u64) -> u64? {
        var i = self.find(k)
        if i < 0 { return null }
        var out = self.vals[i as usize]
        self.keys.swap_remove(i as usize)
        self.vals.swap_remove(i as usize)
        return out
    }

    pub fn shift_remove(self, k: u64) -> u64? {
        var i = self.find(k)
        if i < 0 { return null }
        var out = self.vals[i as usize]
        self.keys.remove(i as usize)
        self.vals.remove(i as usize)
        return out
    }

    pub fn clear(self) {
        self.keys.clear()
        self.vals.clear()
    }

    pub fn retain_mod(self, m: u64, r: u64) {
        var nk: [u64]
        var nv: [u64]
        for var i: usize = 0; i < self.keys.size(); i += 1 {
            if self.keys[i] % m != r {
                nk.push(self.keys[i])
                nv.push(self.vals[i])
            }
        }
        self.keys = nk
        self.vals = nv
    }
}

var failed: bool = false
var peak_map: usize = 0
var peak_set: usize = 0
var peak_collide: usize = 0

fn fail(stream: u64, at: u64, const what: string) {
    if !failed { io::println(f"FAIL stream {stream} at {at}: {what}") }
    failed = true
    failures += 1
}

fn same_map(const m: {u64: u64}, const r: Model, stream: u64, at: u64) {
    if m.size() != r.keys.size() { fail(stream, at, f"size {m.size()} vs {r.keys.size()}"); return }
    var i: usize = 0
    for (k, v) in m {
        if k != r.keys[i] || v != r.vals[i] { fail(stream, at, f"pair {i}: ({k}, {v}) vs ({r.keys[i]}, {r.vals[i]})"); return }
        i += 1
    }
    var j: usize = 0
    for e in m.entries() {
        if e.key != r.keys[j] || e.value != r.vals[j] { fail(stream, at, f"entries[{j}]"); return }
        j += 1
    }
    if r.keys.size() > 0 {
        var f? = m.first()
        var l? = m.last()
        if !f? || !l? || f->key != r.keys[0] || l->key != r.keys[r.keys.size() - 1] { fail(stream, at, "first or last"); return }
    } else if m.first()? || m.last()? {
        fail(stream, at, "first or last of an empty map")
    }
}

var ret_mod: u64 = 7
var ret_rem: u64 = 0

fn keep_mod(k: *const u64, v: *u64) -> bool { return *k % ret_mod != ret_rem }
fn make_seven() -> u64 { return 7 }
fn add(a: u64, b: u64) -> u64 { return a + b }

fn run_map(seed: u64, ops: u64) {
    var m: {u64: u64}
    var r = Model()
    var g = Rng(seed)
    var space: u64 = 64
    var growing = false
    for var at: u64 = 0; at < ops && !failed; at += 1 {
        if at % 10000 == 0 {
            var sizes: [u64] = [16, 64, 300, 1000, 4000, 40]
            space = sizes[g.below(6) as usize]
            growing = !growing
        }
        var k = g.below(space)
        var v = g.next() % 1000
        var c = g.below(1000)
        if growing && c >= 500 && c < 790 { c -= 480 }
        if growing && ((c >= 790 && c < 794) || (c >= 803 && c < 805)) { c = 10 }
        var whole = false
        if c < 220 {
            var old? = m.insert(k, v)
            var want? = r.put(k, v)
            if old? != want? || (old? && old != want) { fail(seed, at, f"insert({k}, {v})") }
        } else if c < 300 {
            m[k] = v
            r.put(k, v)
        } else if c < 370 {
            m[k] += 3
            var i = r.find(k)
            if i < 0 { r.put(k, 3) } else { r.vals[i as usize] += 3 }
        } else if c < 420 {
            var back? = m.try_insert(k, v)
            if r.find(k) >= 0 {
                if !back? || back != v { fail(seed, at, f"try_insert({k}) on a present key") }
            } else {
                if back? { fail(seed, at, f"try_insert({k}) on a new key") }
                r.put(k, v)
            }
        } else if c < 460 {
            var *p = m.get_or_insert(k, v)
            if r.find(k) < 0 { r.put(k, v) }
            if *p != r.vals[r.find(k) as usize] { fail(seed, at, f"get_or_insert({k})") }
        } else if c < 480 {
            var *p = m.get_or_default(k)
            if r.find(k) < 0 { r.put(k, 0) }
            if *p != r.vals[r.find(k) as usize] { fail(seed, at, f"get_or_default({k})") }
        } else if c < 500 {
            var *p = m.get_or_insert_with(k, make_seven)
            if r.find(k) < 0 { r.put(k, 7) }
            if *p != r.vals[r.find(k) as usize] { fail(seed, at, f"get_or_insert_with({k})") }
        } else if c < 620 {
            var out? = m.swap_remove(k)
            var want? = r.swap_remove(k)
            if out? != want? || (out? && out != want) { fail(seed, at, f"swap_remove({k})") }
        } else if c < 740 {
            var out? = m.shift_remove(k)
            var want? = r.shift_remove(k)
            if out? != want? || (out? && out != want) { fail(seed, at, f"shift_remove({k})") }
        } else if c < 790 {
            var out? = m.pop()
            if r.keys.size() == 0 {
                if out? { fail(seed, at, "pop on an empty map") }
            } else {
                var lk = r.keys[r.keys.size() - 1]
                var lv = r.vals[r.vals.size() - 1]
                r.keys.pop()
                r.vals.pop()
                if !out? || out.0 != lk || out.1 != lv { fail(seed, at, "pop") }
            }
        } else if c < 794 {
            ret_mod = 5 + g.below(5)
            ret_rem = g.below(ret_mod)
            m.retain(keep_mod)
            r.retain_mod(ret_mod, ret_rem)
            whole = true
        } else if c < 799 {
            var other: {u64: u64}
            var n = g.below(7)
            for var i: u64 = 0; i < n; i += 1 { other.insert(g.below(space), g.next() % 1000) }
            // The model merges in other's order.
            var ok: [u64]
            var ov: [u64]
            for (a, b) in other { ok.push(a); ov.push(b) }
            for var i: usize = 0; i < ok.size(); i += 1 {
                var j = r.find(ok[i])
                if j >= 0 { r.vals[j as usize] += ov[i] } else { r.put(ok[i], ov[i]) }
            }
            m.merge(other, add)
            whole = true
        } else if c < 803 {
            var items: [(u64, u64)]
            var n = g.below(7)
            for var i: u64 = 0; i < n; i += 1 { items.push((g.below(space), g.next() % 1000)) }
            for var i: usize = 0; i < items.size(); i += 1 { r.put(items[i].0, items[i].1) }
            m.extend_from(items)
            whole = true
        } else if c < 805 {
            m.clear()
            r.clear()
            whole = true
        } else if c < 815 {
            m = m.copy()
            whole = true
        } else if c < 820 {
            if g.below(2) == 0 { m.reserve(g.below(3000) as usize) } else { m.shrink_to_fit() }
            whole = true
        } else {
            var *p? = m.get(k)
            var i = r.find(k)
            if (i >= 0) != p? || (p? && *p != r.vals[i as usize]) { fail(seed, at, f"get({k})") }
            if m.contains(k) != (i >= 0) || (k in m) != (i >= 0) { fail(seed, at, f"contains({k})") }
            var e? = m.get_entry(k)
            if (i >= 0) != e? || (e? && (e->key != k || e->value != r.vals[i as usize])) { fail(seed, at, f"get_entry({k})") }
        }
        if m.size() > peak_map { peak_map = m.size() }
        if m.size() != r.keys.size() { fail(seed, at, f"size after op class {c}") }
        if whole || at % 16 == 0 { same_map(m, r, seed, at) }
    }
    same_map(m, r, seed, ops)
}

/// The set's model: elements in order.
fn find_in(const v: [u64], x: u64) -> isize {
    for var i: usize = 0; i < v.size(); i += 1 {
        if v[i] == x { return i as isize }
    }
    return -1
}

fn same_set(const s: {u64}, const model: [u64], stream: u64, at: u64) {
    if s.size() != model.size() { fail(stream, at, f"size {s.size()} vs {model.size()}"); return }
    var i: usize = 0
    for x in s {
        if x != model[i] { fail(stream, at, f"element {i}: {x} vs {model[i]}"); return }
        i += 1
    }
    var j: usize = 0
    for x in s.items() {
        if x != model[j] { fail(stream, at, f"items[{j}]"); return }
        j += 1
    }
    if model.size() > 0 {
        var f? = s.first()
        var l? = s.last()
        if !f? || !l? || *f != model[0] || *l != model[model.size() - 1] { fail(stream, at, "first or last"); return }
    } else if s.first()? || s.last()? {
        fail(stream, at, "first or last of an empty set")
    }
}

fn keep_set_mod(x: *const u64) -> bool { return *x % ret_mod != ret_rem }

fn small_set(g: *Rng, space: u64) -> {u64} {
    var s: {u64}
    var n = g->below(9)
    for var i: u64 = 0; i < n; i += 1 { s.insert(g->below(space)) }
    return s
}

fn items_of(const s: {u64}) -> [u64] {
    var v: [u64]
    for x in s { v.push(x) }
    return v
}

fn lazy_text(which: u64, const a: {u64}, const b: {u64}) -> [u64] {
    var out: [u64]
    if which == 0 { for x in a.set_union(b) { out.push(*x) } }
    if which == 1 { for x in a.set_intersection(b) { out.push(*x) } }
    if which == 2 { for x in a.set_difference(b) { out.push(*x) } }
    if which == 3 { for x in a.set_xor(b) { out.push(*x) } }
    return out
}

fn run_set(seed: u64, ops: u64) {
    var s: {u64}
    var model: [u64]
    var g = Rng(seed)
    var space: u64 = 64
    var growing = false
    for var at: u64 = 0; at < ops && !failed; at += 1 {
        if at % 10000 == 0 {
            var sizes: [u64] = [16, 64, 300, 1000, 4000, 40]
            space = sizes[g.below(6) as usize]
            growing = !growing
        }
        var k = g.below(space)
        var c = g.below(1000)
        if growing && c >= 400 && c < 760 { c -= 380 }
        if growing && ((c >= 760 && c < 765) || (c >= 835 && c < 837)) { c = 10 }
        var whole = false
        if c < 280 {
            var added = s.insert(k)
            var present = find_in(model, k) >= 0
            if added == present { fail(seed, at, f"insert({k}) returned {added}") }
            if !present { model.push(k) }
        } else if c < 330 {
            var old? = s.replace(k)
            var i = find_in(model, k)
            if (i >= 0) != old? || (old? && old != k) { fail(seed, at, f"replace({k})") }
            if i < 0 { model.push(k) }
        } else if c < 460 {
            var had = s.swap_remove(k)
            var i = find_in(model, k)
            if had != (i >= 0) { fail(seed, at, f"swap_remove({k})") }
            if i >= 0 { model.swap_remove(i as usize) }
        } else if c < 580 {
            var had = s.shift_remove(k)
            var i = find_in(model, k)
            if had != (i >= 0) { fail(seed, at, f"shift_remove({k})") }
            if i >= 0 { model.remove(i as usize) }
        } else if c < 660 {
            var t? = s.take(k)
            var i = find_in(model, k)
            if (i >= 0) != t? || (t? && t != k) { fail(seed, at, f"take({k})") }
            if i >= 0 { model.swap_remove(i as usize) }
        } else if c < 760 {
            var p? = s.pop()
            if model.size() == 0 {
                if p? { fail(seed, at, "pop on an empty set") }
            } else {
                var last? = model.pop()
                if !p? || p != last { fail(seed, at, "pop") }
            }
        } else if c < 765 {
            ret_mod = 5 + g.below(5)
            ret_rem = g.below(ret_mod)
            s.retain(keep_set_mod)
            var nm: [u64]
            for x in model { if x % ret_mod != ret_rem { nm.push(x) } }
            model = nm
            whole = true
        } else if c < 790 {
            var o = small_set(&g, space)
            var which = g.below(4)
            var om = items_of(o)
            var expect: [u64]
            if which == 0 {
                // |=: other's new elements append.
                for x in om { if find_in(model, x) < 0 { model.push(x) } }
                s |= o
            } else if which == 1 {
                // &=: survivors in self's order.
                for x in model { if find_in(om, x) >= 0 { expect.push(x) } }
                model = expect
                s &= o
            } else if which == 2 {
                for x in model { if find_in(om, x) < 0 { expect.push(x) } }
                model = expect
                s -= o
            } else {
                for x in model { if find_in(om, x) < 0 { expect.push(x) } }
                for x in om { if find_in(model, x) < 0 { expect.push(x) } }
                model = expect
                s ^= o
            }
            whole = true
        } else if c < 830 {
            // The lazy operations, against the model's order rule.
            var o = small_set(&g, space)
            var om = items_of(o)
            var which = g.below(4)
            var expect: [u64]
            if which == 0 {
                for x in model { expect.push(x) }
                for x in om { if find_in(model, x) < 0 { expect.push(x) } }
            } else if which == 1 {
                // The smaller set's order, self's when equal.
                if om.size() < model.size() {
                    for x in om { if find_in(model, x) >= 0 { expect.push(x) } }
                } else {
                    for x in model { if find_in(om, x) >= 0 { expect.push(x) } }
                }
            } else if which == 2 {
                for x in model { if find_in(om, x) < 0 { expect.push(x) } }
            } else {
                for x in model { if find_in(om, x) < 0 { expect.push(x) } }
                for x in om { if find_in(model, x) < 0 { expect.push(x) } }
            }
            var got = lazy_text(which, s, o)
            if got.size() != expect.size() { fail(seed, at, f"lazy op {which}: {got.size()} elements, want {expect.size()}") }
            else {
                for var i: usize = 0; i < got.size(); i += 1 {
                    if got[i] != expect[i] { fail(seed, at, f"lazy op {which}: element {i}"); break }
                }
            }
        } else if c < 835 {
            // Equality ignores order.
            var o = s.copy()
            var oc = items_of(o)
            var rev: {u64}
            var i = oc.size()
            while i > 0 {
                i -= 1
                rev.insert(oc[i])
            }
            if !(rev == s) || !(s == rev) { fail(seed, at, "== of a set and its reversed copy") }
            if s.size() > 0 {
                var other = s.copy()
                other.swap_remove(oc[0])
                if other == s || s == other { fail(seed, at, "== of a set and a smaller one") }
                other.insert(oc[0] + 100000)
                if other == s { fail(seed, at, "== of two sets with one different element") }
            }
        } else if c < 837 {
            s.clear()
            model.clear()
            whole = true
        } else if c < 847 {
            s = s.copy()
            whole = true
        } else if c < 852 {
            if g.below(2) == 0 { s.reserve(g.below(3000) as usize) } else { s.shrink_to_fit() }
            whole = true
        } else {
            var i = find_in(model, k)
            if s.contains(k) != (i >= 0) || (k in s) != (i >= 0) { fail(seed, at, f"contains({k})") }
            var g2? = s.get(k)
            if (i >= 0) != g2? || (g2? && *g2 != k) { fail(seed, at, f"get({k})") }
        }
        if s.size() > peak_set { peak_set = s.size() }
        if s.size() != model.size() { fail(seed, at, f"size after op class {c}") }
        if whole || at % 16 == 0 { same_set(s, model, seed, at) }
    }
    same_set(s, model, seed, ops)
}

// A key that hashes to sixteen values; equality is by v.
struct HKey {
    pub var v: u64
}

extend HKey impl Hash {
    fn hash(const self, @inout h: Hasher) { h.write_u64(self.v % 16) }
    fn op == (const self, const o: HKey) -> bool { return self.v == o.v }
}

extend HKey impl Copyable {
    fn copy(const self) -> HKey { return HKey { v: self.v } }
}

fn same_hmap(const m: {HKey: u64}, const r: Model, stream: u64, at: u64) {
    if m.size() != r.keys.size() { fail(stream, at, f"size {m.size()} vs {r.keys.size()}"); return }
    var i: usize = 0
    for (const *k, const *v) in m {
        if k->v != r.keys[i] || *v != r.vals[i] { fail(stream, at, f"pair {i}"); return }
        i += 1
    }
}

fn keep_hmod(k: *const HKey, v: *u64) -> bool { return k->v % ret_mod != ret_rem }

fn run_collide(seed: u64, ops: u64) {
    var m: {HKey: u64}
    var r = Model()
    var g = Rng(seed)
    var space: u64 = 200
    for var at: u64 = 0; at < ops && !failed; at += 1 {
        if at % 10000 == 0 { space = 30 + g.below(400) }
        var k = g.below(space)
        var v = g.next() % 1000
        var c = g.below(1000)
        var whole = false
        if c < 260 {
            var old? = m.insert(HKey { v: k }, v)
            var want? = r.put(k, v)
            if old? != want? || (old? && old != want) { fail(seed, at, f"insert({k})") }
        } else if c < 360 {
            m[HKey { v: k }] = v
            r.put(k, v)
        } else if c < 440 {
            m[HKey { v: k }] += 2
            var i = r.find(k)
            if i < 0 { r.put(k, 2) } else { r.vals[i as usize] += 2 }
        } else if c < 600 {
            var out? = m.swap_remove(HKey { v: k })
            var want? = r.swap_remove(k)
            if out? != want? || (out? && out != want) { fail(seed, at, f"swap_remove({k})") }
        } else if c < 760 {
            var out? = m.shift_remove(HKey { v: k })
            var want? = r.shift_remove(k)
            if out? != want? || (out? && out != want) { fail(seed, at, f"shift_remove({k})") }
        } else if c < 830 {
            var out? = m.pop()
            if r.keys.size() == 0 {
                if out? { fail(seed, at, "pop on an empty map") }
            } else {
                var lk = r.keys[r.keys.size() - 1]
                var lv = r.vals[r.vals.size() - 1]
                r.keys.pop()
                r.vals.pop()
                if !out? || out.0.v != lk || out.1 != lv { fail(seed, at, "pop") }
            }
        } else if c < 834 {
            ret_mod = 5 + g.below(5)
            ret_rem = g.below(ret_mod)
            m.retain(keep_hmod)
            r.retain_mod(ret_mod, ret_rem)
            whole = true
        } else if c < 840 {
            m = m.copy()
            whole = true
        } else {
            var *p? = m.get(HKey { v: k })
            var i = r.find(k)
            if (i >= 0) != p? || (p? && *p != r.vals[i as usize]) { fail(seed, at, f"get({k})") }
        }
        if m.size() > peak_collide { peak_collide = m.size() }
        if m.size() != r.keys.size() { fail(seed, at, f"size after op class {c}") }
        if whole || at % 16 == 0 { same_hmap(m, r, seed, at) }
    }
    same_hmap(m, r, seed, ops)
}

fn main() -> i32 {
    run_map(1, 200000)
    ck(!failed, "map: 200000 operations against the model")
    run_set(2, 200000)
    ck(!failed, "set: 200000 operations against the model")
    run_collide(3, 100000)
    ck(!failed, "colliding map: 100000 operations against the model")
    ck(peak_map >= 1500 && peak_set >= 500 && peak_collide >= 100, "the streams reached sizes that cross several table growths")
    io::println(f"peak sizes {peak_map} {peak_set} {peak_collide}")
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
