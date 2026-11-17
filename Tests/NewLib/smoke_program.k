// One program on the two-word library: text is split into lines and fields,
// numbers are parsed, a `{string: [i32]}` map is filled, its keys and each
// list are sorted, and a report is formatted with f-strings. The same output
// at -O0 and at -O2.

import std::io::*

fn add_score(@inout scores: {string: [i32]}, const name: string, n: i32) {
    var *list? = scores.get_mut(name)
    if list? {
        list->push(n)
        return
    }

    var first: [i32] = [n]
    scores.insert(name.to_owned(), first)
}

fn main() -> i32 {
    var text = "alice: 3, 9, 4\nbob: 12, 7\ncarol:\nalice: 1\nnot a record\ndave: 5, x, 6\nélodie: 8, -2\n"
    var scores: {string: [i32]}
    var bad_tokens = 0
    var skipped    = 0

    for line in text.lines() {
        var pr? = line.split_once(":")
        if !pr? {
            skipped += 1
            continue
        }

        var pair = unwrap!(pr)
        var name = pair.0.trim()
        for tok in pair.1.split(",") {
            var t = tok.trim()
            if t.is_empty() {
                continue
            }

            var err = ParseError { at: 0, kind: ParseErrorKind::None }
            var n?  = i32::from_str(t, &err)
            if n? {
                add_score(&scores, name, n)
            } else {
                bad_tokens += 1
            }
        }
    }

    var names: [string]
    for k in scores.keys() {
        names.push((*k).copy())
    }

    names.sort()

    var grand: i64 = 0
    for *name in names {
        var *list? = scores.get_mut(*name)
        if !list? {
            return 2
        }

        var nums: [i32;] = *list
        nums.sort()
        var total: i64 = 0
        for x in nums {
            total += x
        }

        grand += total
        var lo = nums[0]
        var hi = nums[nums.size() - 1]
        println(f"{*name}: n={nums.size()} total={total} min={lo} max={hi} mean={(total as f64) / (nums.size() as f64)}")
    }

    println(f"people={names.size()} grand={grand} bad={bad_tokens} skipped={skipped} hex={grand:x}")
    return 0
}

// CHECK: alice: n=4 total=17 min=1 max=9 mean=4.25
// CHECK-NEXT: bob: n=2 total=19 min=7 max=12 mean=9.5
// CHECK-NEXT: dave: n=2 total=11 min=5 max=6 mean=5.5
// CHECK-NEXT: élodie: n=2 total=6 min=-2 max=8 mean=3
// CHECK-NEXT: people=4 grand=53 bad=1 skipped=1 hex=35

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
