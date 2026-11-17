// Slice rows (ops.toml, group "slice") on the old library. Its `[T;]` has
// indexing and sub-slicing only, so every row waits for the new one.
ffi "c++" import "bench.h"

fn main() -> i32 {
    bench_init_env()
    bench_todo("slice.sort_unstable_i32", 1000000)
    bench_todo("slice.sort_unstable_u64", 1000000)
    bench_todo("slice.sort_unstable_string", 1000000)
    bench_todo("slice.sort_unstable_struct64", 1000000)
    bench_todo("slice.sort_stable_i32", 1000000)
    bench_todo("slice.sort_stable_u64", 1000000)
    bench_todo("slice.sort_stable_string", 1000000)
    bench_todo("slice.sort_stable_struct64", 1000000)
    bench_todo("slice.binary_search", 1024)
    bench_todo("slice.binary_search", 10000000)
    bench_todo("slice.reverse", 4096)
    bench_todo("slice.reverse", 1000000)
    bench_todo("slice.fill", 4096)
    bench_todo("slice.fill", 1000000)
    return 0
}
