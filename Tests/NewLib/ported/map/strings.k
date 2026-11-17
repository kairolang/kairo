// HashMap with string keys and values, and with container values: UTF-8
// keys, keys that differ in a late byte or in length, the empty key, the
// setter and place form copying a key only on a miss, a map of vectors used
// as a multimap, nested maps, and thousands of mixed-length keys. Strings
// are move-only: values come out of removals and inserts by move.
//
// Cases from libc++ test/std/containers/unord/unord.map/unord.map.elem/ (index, at)
// Cases from Rust library/std/src/collections/hash/map/tests.rs
// Cases from hashbrown src/map.rs tests (insert, find, entry with owned keys)

import std::io

var checks: u64 = 0
var failures: u64 = 0
var live: i64 = 0
var errors: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

class Obj {
    pub var v: u64
    var state: u64

    pub fn Obj(self, v: u64) {
        self.v = v
        self.state = 1
        live += 1
    }

    @move pub fn Obj(self, other: Self) {
        if other.state != 1 { errors += 1 }
        self.v = other.v
        self.state = 1
        other.state = 2
        live += 1
    }

    pub fn op finally(self) {
        if self.state == 0 { errors += 1 }
        self.state = 0
        live -= 1
    }
}

fn long_key(i: u64, pad: u64) -> string {
    var s = f"{i}"
    for var j: u64 = 0; j < pad; j += 1 { s.push_str("-pad") }
    return s
}

fn test_utf8_keys() {
    var m: {string: u64}
    m.insert("héllo".copy(), 1)
    m.insert("日本語".copy(), 2)
    m.insert("🙂".copy(), 3)
    m.insert("héllo!".copy(), 4)
    ck(m.size() == 4, "utf-8: four distinct keys")
    ck(m["héllo"] == 1 && m["日本語"] == 2 && m["🙂"] == 3 && m["héllo!"] == 4, "utf-8: lookup by literal")
    ck(!m.contains("hello") && !m.contains("日本") && !m.contains("日本語語"), "utf-8: near misses")
    ck(m.swap_remove("🙂") == 3 && !m.contains("🙂"), "utf-8: removal")
}

fn test_keys_differing_late() {
    var m: {string: u64}
    var base = long_key(1, 20)
    m.insert(base.copy(), 1)
    var other = base.copy()
    other.push_str("x")
    m.insert(other.copy(), 2)
    ck(m.size() == 2 && m[base] == 1 && m[other] == 2, "a key and the same key plus one byte")
    var swapped = long_key(2, 20)
    m.insert(swapped.copy(), 3)
    ck(m.size() == 3 && m.contains(long_key(2, 20)), "keys of 80+ bytes differing in the first byte")
    ck(!m.contains(long_key(1, 19)) && !m.contains(long_key(1, 21)), "keys of neighbouring lengths")
}

fn test_empty_and_one_string() {
    var m: {string: string}
    ck(!m.contains("") && !m.get("")?, "empty map: the empty key misses")
    m.insert("".copy(), "".copy())
    ck(m.size() == 1 && m[""] == "" && m.contains(""), "the empty key and the empty value")
    m.insert("a".copy(), "b".copy())
    ck(m.size() == 2 && m["a"] == "b" && m[""] == "", "an empty key beside a one-byte key")
    var old? = m.insert("".copy(), "now".copy())
    ck(old? && old == "" && m[""] == "now", "replace of the empty key returns the empty string")
}

fn test_setter_copies_key() {
    var m: {string: string}
    var k = "name".copy()
    m[k] = "first"
    ck(k == "name" && m["name"] == "first", "setter: the caller keeps its key")
    m[k] = "second"
    ck(m.size() == 1 && m["name"] == "second", "setter: replace")
    m[k] += "-more"
    ck(m["name"] == "second-more" && m.size() == 1, "place form on a present key")
    var j = "other".copy()
    m[j] += "start"
    ck(j == "other" && m["other"] == "start" && m.size() == 2, "place form on a missing key keeps the caller's key")
}

fn test_multimap_pattern() {
    var m: {string: [u64]}
    for var i: u64 = 0; i < 300; i += 1 {
        m[f"group{i % 7}"].push(i)
    }
    ck(m.size() == 7, "vector values: seven groups")
    ck(m["group0"].size() == 43 && m["group6"].size() == 42, "vector values: group sizes")
    ck(m["group3"][0] == 3 && m["group3"][1] == 10, "vector values: pushed in order")
    var total: u64 = 0
    for (const *k, const *v) in m {
        for x in *v { total += x }
    }
    ck(total == 299 * 300 / 2, "vector values: every element kept")
    var c = m.copy()
    c["group0"].push(1000)
    ck(m["group0"].size() == 43 && c["group0"].size() == 44, "vector values: copy is deep")
}

fn test_nested_maps() {
    var m: {string: {string: u64}}
    m["a"]["x"] = 1
    m["a"]["y"] = 2
    m["b"]["x"] = 3
    ck(m.size() == 2 && m["a"].size() == 2 && m["b"].size() == 1, "nested: sizes")
    ck(m["a"]["y"] == 2 && m["b"]["x"] == 3, "nested: lookups")
    m["a"]["x"] += 10
    ck(m["a"]["x"] == 11, "nested: place form")
    var r? = m.swap_remove("a")
    ck(r? && r.size() == 2 && r["x"] == 11 && m.size() == 1, "nested: removal moves the inner map out")
}

fn test_many_string_keys() {
    var m: {string: string}
    for var i: u64 = 0; i < 4000; i += 1 { m.insert(long_key(i, i % 9), f"v{i}") }
    var bad: u64 = 0
    for var i: u64 = 0; i < 4000; i += 1 {
        var *p? = m.get(long_key(i, i % 9))
        if !p? || *p != f"v{i}" { bad += 1 }
    }
    ck(bad == 0 && m.size() == 4000, "4000 keys of mixed lengths")
    var r: u64 = 0
    for var i: u64 = 0; i < 4000; i += 5 {
        if m.swap_remove(long_key(i, i % 9))? { r += 1 }
    }
    ck(r == 800 && m.size() == 3200, "removing every fifth")
    var c = m.copy()
    m.merge(c, take_left)
    ck(m.size() == 3200 && m.contains(long_key(1, 1)), "merge of a copy changes nothing")
    var t? = m.pop()
    ck(t?, "pop of a string map")
}

fn take_left(a: string, b: string) -> string { return a }

fn test_values_are_moved_not_copied() {
    var m: {u64: string}
    var s = "payload".copy()
    for var i: u64 = 0; i < 10; i += 1 { m.insert(i, s.copy()) }
    var r? = m.swap_remove(3)
    ck(r? && r == "payload" && m.size() == 9, "string value moved out by swap_remove")
    r = m.shift_remove(4)
    ck(r? && r == "payload", "string value moved out by shift_remove")
    var old? = m.insert(5, "new".copy())
    ck(old? && old == "payload" && m[5] == "new", "string value returned by insert")
    var back? = m.try_insert(5, "other".copy())
    ck(back? && back == "other" && m[5] == "new", "string value handed back by try_insert")
}

fn main() -> i32 {
    test_utf8_keys()
    test_keys_differing_late()
    test_empty_and_one_string()
    test_setter_copies_key()
    test_multimap_pattern()
    test_nested_maps()
    test_many_string_keys()
    test_values_are_moved_not_copied()
    io::println(f"{checks} checks, {failures} failures")
    return failures as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: {{[0-9]+}} checks, 0 failures
