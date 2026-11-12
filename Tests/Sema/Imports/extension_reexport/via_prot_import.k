import lib::pt::Q
import lib::protted
import lib::inside::inside
fn main() -> i32 {
    var q = Q { v: 1 }
    return inside(q) + q.via_prot() - 12
}

// --- lit wiring -----------------------------------------------------------
// A `prot import` is a re-export to the files of its own module only
// (imports.mdx: "visible to sibling files in same library"), so it carries
// an extension onward only to an importer in that module. lib/inside.k is
// in lib's module and sees lib/protext.k's `via_prot` through lib/protted.k's
// `prot import`; this file is outside every module, so the same edge does
// not carry it here.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:     via_prot_import.k:6:26: error [R025E]: no member named 'via_prot' in 'Q'
