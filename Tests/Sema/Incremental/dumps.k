// Incremental Sema, phase 1 (Compiler/Spec/IncrementalSema.md): what
// --dump-interface and --dump-deps write for a two-file project.
//
// Pinned here: the DeclId of every kind of declaration lib.k exports (a
// function per overload, a generic, a constructor, an operator, a field, an
// enum variant, an extension member with the type it extends, a module
// member, an alias, a constant), the names each scope declares, and the rows
// main.k's check logs against lib.k: the names it looked up per scope, the
// overlay names, and what it read of each declaration (signature, layout,
// body). Hashes are matched by shape only: they are defined by the spec, not
// by this file.
//
// Also pinned: two runs write the same bytes, and neither dump holds the
// project directory anywhere but in its top-level `root`.

// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/dump && %kairo main.k --type-check-only --dump-interface=%t.d/i.json --dump-deps=%t.d/d.json
// RUN: %FileCheck %s --check-prefix=IFACE --input-file=%t.d/i.json
// RUN: %FileCheck %s --check-prefix=DEPS --input-file=%t.d/d.json
// RUN: cd %S/Inputs/dump && %kairo main.k --type-check-only --dump-interface=%t.d/i2.json --dump-deps=%t.d/d2.json
// RUN: cmp %t.d/i.json %t.d/i2.json
// RUN: cmp %t.d/d.json %t.d/d2.json
// RUN: tail -n +2 %t.d/i.json | %FileCheck %s --check-prefix=NOPATH
// RUN: tail -n +2 %t.d/d.json | %FileCheck %s --check-prefix=NOPATH
// NOPATH-NOT: Inputs

// The flags are dumps only: without them nothing is written and the result is the same.
// RUN: cd %S/Inputs/dump && %kairo main.k --type-check-only --print-sema > %t.d/off.txt
// RUN: cd %S/Inputs/dump && %kairo main.k --type-check-only --print-sema --dump-interface=%t.d/i3.json --dump-deps=%t.d/d3.json > %t.d/on.txt
// RUN: cmp %t.d/off.txt %t.d/on.txt
// IFACE: {"version": 1, "root": "{{.*}}dump", "files": [
// IFACE: {"module": "lib", "path": "lib.k", "phase": "Checked", "hash": "{{[0-9a-f]+}}", "macros": "", "decls": [
// IFACE-NEXT:   {"id": "lib#class:Box", "scope": "", "name": "Box", "kind": "class", "I": "{{[0-9a-f]+}}", "body": "", "refs": []},
// IFACE-NEXT:   {"id": "lib#class:Box/field:v", "scope": "lib#class:Box", "name": "v", "kind": "field", "I": "{{[0-9a-f]+}}", "body": "", "refs": []},
// IFACE-NEXT:   {"id": "lib#class:Box/fn:Box(self,i32)", "scope": "lib#class:Box", "name": "<ctor>", "kind": "fn", "I": "{{[0-9a-f]+}}", "body": "{{[0-9a-f]+}}", "refs": ["lib#class:Box"]},
// IFACE-NEXT:   {"id": "lib#class:Box/fn:get(self)", "scope": "lib#class:Box", "name": "get", "kind": "fn", "I": "{{[0-9a-f]+}}", "body": "{{[0-9a-f]+}}", "refs": ["lib#class:Box"]},
// IFACE-NEXT:   {"id": "lib#class:Box/fn:op +(self,i32)", "scope": "lib#class:Box", "name": "op#{{[0-9]+}}", "kind": "fn", "I": "{{[0-9a-f]+}}", "body": "{{[0-9a-f]+}}", "refs": ["lib#class:Box"]},
// IFACE-NEXT:   {"id": "lib#enum:Mode", "scope": "", "name": "Mode", "kind": "enum", "I": "{{[0-9a-f]+}}", "body": "", "refs": []},
// IFACE-NEXT:   {"id": "lib#enum:Mode/variant:Off", "scope": "lib#enum:Mode", "name": "Off", "kind": "variant", "I": "{{[0-9a-f]+}}", "body": "", "refs": []},
// IFACE-NEXT:   {"id": "lib#enum:Mode/variant:On", "scope": "lib#enum:Mode", "name": "On", "kind": "variant", "I": "{{[0-9a-f]+}}", "body": "", "refs": []},
// IFACE-NEXT:   {"id": "lib#ext:P/fn:sum(self)", "scope": "lib#ext:P", "name": "sum", "kind": "fn", "I": "{{[0-9a-f]+}}", "body": "{{[0-9a-f]+}}", "ext": "lib#struct:P", "refs": ["lib#struct:P"]},
// IFACE-NEXT:   {"id": "lib#fn:add(i32,i32)", "scope": "", "name": "add", "kind": "fn", "I": "{{[0-9a-f]+}}", "body": "{{[0-9a-f]+}}", "refs": []},
// IFACE-NEXT:   {"id": "lib#fn:add(i64,i64)", "scope": "", "name": "add", "kind": "fn", "I": "{{[0-9a-f]+}}", "body": "{{[0-9a-f]+}}", "refs": []},
// IFACE-NEXT:   {"id": "lib#fn:ident<1>(T)", "scope": "", "name": "ident", "kind": "fn", "I": "{{[0-9a-f]+}}", "body": "{{[0-9a-f]+}}", "refs": []},
// IFACE-NEXT:   {"id": "lib#module:util", "scope": "", "name": "util", "kind": "module", "I": "{{[0-9a-f]+}}", "body": "", "refs": []},
// IFACE-NEXT:   {"id": "lib#module:util/fn:helper(i32)", "scope": "lib#module:util", "name": "helper", "kind": "fn", "I": "{{[0-9a-f]+}}", "body": "{{[0-9a-f]+}}", "refs": []},
// IFACE-NEXT:   {"id": "lib#struct:P", "scope": "", "name": "P", "kind": "struct", "I": "{{[0-9a-f]+}}", "body": "", "refs": []},
// IFACE-NEXT:   {"id": "lib#struct:P/field:x", "scope": "lib#struct:P", "name": "x", "kind": "field", "I": "{{[0-9a-f]+}}", "body": "", "refs": []},
// IFACE-NEXT:   {"id": "lib#struct:P/field:y", "scope": "lib#struct:P", "name": "y", "kind": "field", "I": "{{[0-9a-f]+}}", "body": "", "refs": []},
// IFACE-NEXT:   {"id": "lib#type:Id", "scope": "", "name": "Id", "kind": "type", "I": "{{[0-9a-f]+}}", "body": "", "refs": []},
// IFACE-NEXT:   {"id": "lib#var:LIMIT", "scope": "", "name": "LIMIT", "kind": "var", "I": "{{[0-9a-f]+}}", "body": "", "refs": []}], "scopes": [
// IFACE-NEXT:   {"scope": "", "ext": "", "names": ["Box", "Id", "LIMIT", "Mode", "P", "add", "ident", "util"]},
// IFACE-NEXT:   {"scope": "lib#class:Box", "ext": "", "names": ["<ctor>", "get", "op#{{[0-9]+}}", "v"]},
// IFACE-NEXT:   {"scope": "lib#enum:Mode", "ext": "", "names": ["Off", "On"]},
// IFACE-NEXT:   {"scope": "lib#ext:P", "ext": "lib#struct:P", "names": ["sum"]},
// IFACE-NEXT:   {"scope": "lib#module:util", "ext": "", "names": ["helper"]},
// IFACE-NEXT:   {"scope": "lib#struct:P", "ext": "", "names": ["x", "y"]}]},
// IFACE-NEXT: {"module": "main", "path": "main.k", "phase": "Checked", "hash": "{{[0-9a-f]+}}", "macros": "", "decls": [
// IFACE-NEXT:   {"id": "main#fn:main()", "scope": "", "name": "main", "kind": "fn", "I": "{{[0-9a-f]+}}", "body": "{{[0-9a-f]+}}", "refs": []},
// IFACE-NEXT:   {"id": "main#var:N", "scope": "", "name": "N", "kind": "var", "I": "{{[0-9a-f]+}}", "body": "", "refs": []}], "scopes": [
// IFACE-NEXT:   {"scope": "", "ext": "", "names": ["N", "main"]}]}

// DEPS: {"module": "main", "path": "main.k", "surface": ["builtin", {{.*}}"lib"], "names": [
// DEPS:   {"module": "lib", "scope": "", "name": "Box"},
// DEPS-NEXT:   {"module": "lib", "scope": "", "name": "Id"},
// DEPS-NEXT:   {"module": "lib", "scope": "", "name": "LIMIT"},
// DEPS-NEXT:   {"module": "lib", "scope": "", "name": "Mode"},
// DEPS-NEXT:   {"module": "lib", "scope": "", "name": "P"},
// DEPS-NEXT:   {"module": "lib", "scope": "", "name": "add"},
// DEPS-NEXT:   {"module": "lib", "scope": "", "name": "ident"},
// DEPS-NEXT:   {"module": "lib", "scope": "", "name": "util"},
// DEPS-NEXT:   {"module": "lib", "scope": "lib#class:Box", "name": "<ctor>"},
// DEPS-NEXT:   {"module": "lib", "scope": "lib#class:Box", "name": "get"},
// DEPS-NEXT:   {"module": "lib", "scope": "lib#enum:Mode", "name": "On"},
// DEPS-NEXT:   {"module": "lib", "scope": "lib#ext:P", "name": "sum"},
// DEPS-NEXT:   {"module": "lib", "scope": "lib#ext:P", "name": "x"},
// DEPS-NEXT:   {"module": "lib", "scope": "lib#module:util", "name": "helper"},
// DEPS-NEXT:   {"module": "lib", "scope": "lib#struct:P", "name": "sum"},
// DEPS-NEXT:   {"module": "lib", "scope": "lib#struct:P", "name": "x"},
// DEPS-NEXT:   {"module": "lib", "scope": "lib#struct:P", "name": "y"}], "overlay": [
// DEPS-NEXT:   {"of": "main", "names": ["Box", "Id", "LIMIT", "Mode", "P", "add", "ident", "util"]}], "decls": [
// DEPS-NEXT:   {"id": "lib#fn:ident<1>(T)", "part": "body"},
// DEPS-NEXT:   {"id": "lib#class:Box", "part": "layout"},
// DEPS-NEXT:   {"id": "lib#enum:Mode", "part": "layout"},
// DEPS-NEXT:   {"id": "lib#struct:P", "part": "layout"},
// DEPS-NEXT:   {"id": "lib#class:Box", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#class:Box/fn:get(self)", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#enum:Mode", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#enum:Mode/variant:On", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#ext:P/fn:sum(self)", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#fn:add(i32,i32)", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#fn:ident<1>(T)", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#module:util", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#module:util/fn:helper(i32)", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#struct:P", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#struct:P/field:x", "part": "sig"},
// DEPS-NEXT:   {"id": "lib#var:LIMIT", "part": "sig"}]}
