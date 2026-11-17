// Linked beside each C++ benchmark in the kcc column. A link that holds
// Kairo code carries the Kairo runtime, whose heap (mimalloc) then serves
// malloc and operator new for the whole program; a kcc link of C++ alone is
// clang's and keeps the C library's heap.
fn bench_kcc_runtime_anchor() -> i32 { return 0 }
