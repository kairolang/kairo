// Every per-module record --incremental-sema writes is valid JSON, whatever
// bytes its module name holds: the entry module is named after its file, and
// a tab in the file name is a control byte, which a JSON string must escape.
// The second run reads the records back and hits.

fn main() -> i32 { return 4 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// A file name cannot hold a tab on Windows.
// UNSUPPORTED: host-windows
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cp %s "%t.d/$(printf 'tab\there').k"
// RUN: cd %t.d && %kairo "$(printf 'tab\there').k" -o a --cache-dir c --incremental-sema
// RUN: python3 -c "import glob, json, sys; fs = glob.glob(sys.argv[1] + '/c/*/mod/*.json'); assert fs; [json.load(open(f)) for f in fs]; print('records', 'ok' if any(json.load(open(f))['module'] == 'tab\there' for f in fs) else 'missing')" %t.d | %FileCheck %s
// CHECK: records ok
// RUN: cd %t.d && %kairo "$(printf 'tab\there').k" -o a --cache-dir c --incremental-sema --print-incr-status | %FileCheck %s --check-prefix=HIT
// HIT: hit
// RUN: %t.d/a; test $? -eq 4
