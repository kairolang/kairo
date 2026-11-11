// RUN: { %kairo %s --type-check-only --cmax-scope-depth=12 2>&1 || true; } | %FileCheck %s --check-prefix=CAP
// RUN: %kairo %s --type-check-only --cmax-scope-depth=256
//
// Inference that meets the resolution stack's depth cap is an error, once.
//
// Every shorthand `var` below is typed on demand by the one above it, so the
// walk of v0 holds a frame per link. At a cap of 12 the demand for v12 finds
// the stack full. It does not return no type and say nothing (which would leave v0..v11
// untyped and the program accepted): the capped declaration is
// reported, and the links that waited on it stay quiet behind that report.
//
// 12 is about the smallest cap the builtin sources still parse under; a
// generous cap leaves the same program clean.

var v0 = v1
var v1 = v2
var v2 = v3
var v3 = v4
var v4 = v5
var v5 = v6
var v6 = v7
var v7 = v8
var v8 = v9
var v9 = v10
var v10 = v11
var v11 = v12
var v12 = v13
// CAP: infer_depth_cap.k:[[@LINE-1]]:1: error [SC001E]: inferring the type of 'v12' exceeded the nested scope limit (12)
var v13: i32 = 1

fn main() -> i32 { return v0 }

// CAP-NOT: error
