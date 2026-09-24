//  build: kairo C5-symbol-dump-skips-function-nested-type-tables.k --print-symbols --type-check-only
// build (alt): ./build/arm64-apple-macosx/debug/bin/kairo C5-symbol-dump-skips-function-nested-type-tables.k --print-sema --type-check-only
// version: kairo-0.1.1+dev.20260907
//
// ### Expected behavior
// CompilerInstance::_dump_symbols_dc and SemaDump's table section should
// recurse into Function/Test/ProcMacro DeclContexts the same way they
// already recurse into type/module/extension DCs, so Inner's table (and
// get's) show up under --print-symbols / --print-sema.
//
// ### Additional context
// Source: Compiler/Driver/CompilerInstance.k (_dump_symbols_dc),
// Compiler/Sema/SemaDump.k. Confirmed live: --print-symbols only shows
// the top-level <tu> scope and never descends into outer's body to show
// Inner's member table at all. --print-sema's own "-- scope symbol
// tables --" section has the same gap it lists only <tu> and never
// shows <tu>::outer::Inner's table, even though the separate
// "-- lexical scopes --" section in the same dump does correctly show
// Inner and Inner::get nested under fn outer. The information exists
// internally; only the table-recursion code path fails to reach it.

fn outer() {
    class Inner {
        var v: i32
        fn get(self) -> i32 {
            return self.v
        }
    }
}
