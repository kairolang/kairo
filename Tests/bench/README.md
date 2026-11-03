# Tests/bench

The same programs written idiomatically in Kairo, C++ and Rust, built at -O3
for the host's baseline target, timed interleaved. Each program reads its
size from `N` (and `DEPTH`/`MODE` for `scopes`) and prints a checksum that
every implementation must agree on.

```fish
./bench-run.fish --smoke 1     # builds everything, small sizes, checks agreement
./bench-run.fish 5             # full sizes, 5 runs each; ~1-3 s per run on a desktop
./bench-run.fish 5 nbody gen   # a subset
```

Tools: `KAIRO`, `KCC`, `CXX_CLANG`, `CXX_GCC`, `RUSTC` override the defaults;
a missing tool skips its column. C++ is built three ways: host clang, host
gcc, and kcc (which links Kairo's runtime, mimalloc included).

| Benchmark | Stresses | Kairo | C++ | Rust |
|---|---|---|---|---|
| `nbody` | f64 math, structs, fixed arrays | class + `[Body; 5]` | `std::array` | `split_at_mut` |
| `btree` | allocation, recursion, teardown | `*Node?`, `@create`/`@destroy` | `unique_ptr` | `Option<Box>` |
| `fannkuch` | integer arrays, permutations | index loops | `std::reverse`/`rotate` | slice `reverse`/`rotate_left` |
| `gsort` | generic sort over an operator bound, closures | interface bound, `fn` params | templates, lambdas | trait bound, `impl Fn` |
| `gsort-lib` | library sort, for reference | (none yet) | `std::sort` | `sort_unstable` |
| `gen` | 3-stage nested generator pipeline | `-> yield T` | C++20 coroutines | iterators |
| `errpath` | 1% failing calls | `panic`/`try`/`catch` | exceptions | `Result` |
| `alloc` | create + destroy a 16-byte object | `create`/`destroy` | `new`/`delete`, `malloc`/`free` | `Box` |
| `interp` | bytecode loop | ADT enum + `match` | tagged struct + `switch` | `enum` + `match` |
| `closures` | stored capturing callbacks | `[fn(i64) -> i64; 3]` | `std::function` | `Box<dyn Fn>` |
| `dispatch` | virtual calls, mixed array | `virtual`/`override` | virtual, `final` classes | `dyn Trait` |
| `wideint` | u64 Miller-Rabin, u128 mulmod | `u128` | `unsigned __int128` | `u128` |
| `fmt` | f64/i64 to text | f-strings | `std::to_chars` | `write!` |
| `spectral` | spectral-norm, f64 | raw buffers | `std::vector` | iterators |
| `slices` | sum, dot, filter over 1M f64 | `for x in xs` | range-for | `iter().sum()` |
| `nullable` | linked-list walk/search | `*Node?`, narrowing | `unique_ptr` | `Option<Box>` |
| `scopes` | scoped-allocator stack (Kairo only) | `AllocatorScope` | | |

Known workarounds in the Kairo sources (compiler bugs, see the repro tar):
`gsort.k` wraps `i64` in `Key` (primitive `extend ... impl` with an operator
fails) and annotates generic locals; `gen.k` yields named variables only;
`spectral.k` avoids the parameter name `out` (SC004E false positive).
