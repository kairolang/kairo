# lib_bench.py: the library rows in every language, timed and counted

`lib_bench.py` builds the builtin-library benchmark programs (the rows
`README` describes, plus the `alloc` group) for every language column and
measures each cell (row and size) for wall time and hardware counters.
Instructions per operation are deterministic and good for tracking a change,
but they hide IPC, branch mispredictions and cache misses: a branchless
binary search, a radix sort or a dense-table lookup can rank differently in
cycles and nanoseconds. Each cell therefore reports, for every column:

| Figure | Source |
|---|---|
| ns/op | the protocol's own timer (`cpp/bench.h`): fastest timed repetition / operations |
| instructions/op, cycles/op | `perf stat` `instructions:u`, `cycles:u` |
| IPC | differenced instructions / differenced cycles |
| branch misses/op | `branch-misses:u` |
| L1d misses/op | `L1-dcache-load-misses:u` |
| LLC misses/op | `LLC-load-misses:u`, or the CPU's equivalent: on AMD Zen, demand fills from DRAM (`ls_dmnd_fills_from_sys.dram_io_near` + `dram_io_far`) |

The event names used are printed in the report. A CPU without one of them
leaves that figure empty and the report says so.

## Columns

| Column | Program | Built with | Bounds checks |
|---|---|---|---|
| Kairo | `kairo/<group>.k` | `kairo -O3 --mcpu <cpu>` | kept |
| Kairo before (optional) | the same | a second kairo, `--kairo-before <bin/kairo>` | as that compiler's library does |
| clang | `cpp/<group>.cpp` | the toolchain's clang++ and libc++, glibc malloc (as run.py) | removed (libc++ hardening mode none) |
| kcc | `cpp/<group>.cpp` | kcc: the C++ compiled alone at `-std=c++20 -c`, then linked with `cpp/kcc_anchor.k`; the same libc++ on the Kairo runtime's mimalloc | removed (the same libc++) |
| gcc | `cpp/<group>.cpp` | `g++ -std=c++20 -O3 -march=<cpu>`, libstdc++ | removed (no `_GLIBCXX_ASSERTIONS`) |
| Rust | `rust/<group>.rs` | `rustc -C opt-level=3 -C target-cpu=<cpu> -C codegen-units=1` | kept |
| Zig | `zig/<group>.zig` | `zig build-exe -O ReleaseFast -mcpu=<cpu> -lc` | removed (ReleaseFast) |
| Go | `go/bench.go <group>.go` | `go build`, `GOAMD64` = the level of the target | kept |
| D (gdc) | `d/bench.d <group>.d` | `gdc -O3 -frelease -fno-weak-templates -march=<cpu>` | removed (`-frelease`, outside `@safe` code) |
| LDC | `d/bench.d <group>.d` | `ldc2 -O3 -release -mcpu=<cpu>` | removed (`-release`, outside `@safe` code) |
| Nim | `nim/<group>.nim` | `nim c -d:danger --passC:-march=<cpu>` | removed (`-d:danger`) |
| Swift | `swift/bench.swift <group>.swift` | `swiftc -O -parse-as-library -target-cpu <cpu>` | kept (`-O`) |

Each column is built at its language's usual release setting, and those
settings differ in safety: Kairo, Rust, Go and Swift keep index bounds
checks; the C++ columns, Zig ReleaseFast, D's `-release` (outside `@safe`
code; only the map keys' hash and equality and the input generator are
`@safe`) and Nim `-d:danger` remove them. A
figure from an unchecked column is not a like-for-like comparison with a
checked one, so the report lists this per column and marks an unchecked
best-other pick with `*`.
The column says what the build setting does to indexing in the program's
own code; a library operation may use unchecked access inside (Swift's
`fill` row writes through `withUnsafeMutableBufferPointer`, as its library
does).

`<cpu>` is one name for every column: by default what clang resolves
`-march=native` to; `--cpu-name x86-64` builds for the baseline. Go takes a
level, not a CPU: x86-64 is `v1`, `x86-64-vN` is `vN`, any other name the
highest level the host supports. Each tool comes from PATH (`swiftc` also
from swiftly's `~/.local/share/swiftly/bin`); `--gxx`, `--rustc`, `--zig`,
`--go`, `--gdc`, `--ldc2`, `--nim`, `--swiftc` name others. A missing tool,
or a program that fails to build, leaves its column empty with a note. The
Kairo toolchain is `--toolchain <bin/>` (kairo, kcc, clang++, llvm-nm), else
`$KAIRO_TOOLCHAIN`, else the installed release above this directory; the
Kairo programs need a compiler and library at least as new as they are. The
report ends with the exact build command of each column.

## Measurement rules

- **One core.** Every process is pinned with `taskset -c` to one CPU
  (`--cpu`, default the last one this process may use).
- **Interleaved, several runs.** A cell is measured in `--runs` rounds
  (default 5). Each round runs every column once, starting one column
  later than the round before. A run of a column is one timed process (time
  driven: at least `--min-ms`, default 200 ms of repetitions) and, for each
  counter pass, two processes of K and 2K repetitions. Every figure is the
  median of the runs, and the spread (min..max) is kept.
- **Counters are differenced.** `perf stat` counts whole processes, so
  K and 2K repetitions are differenced and divided by K repetitions'
  operations: start-up, input generation and the warm-up repetition cancel.
  K is half the repetitions of the column's first timed process, or `--k`.
  The counters still include each repetition's untimed setup, which ns/op
  does not: on rows with a large setup (the sorts copy their input) cycles
  per operation exceed what ns/op implies.
- **No multiplexing.** The counters are read in two passes of at most four
  events each (instructions, cycles, branches, branch misses; then the
  cache misses), one `perf stat` call per pass, so no count is scaled. A
  count that was scaled anyway is marked in the cell's table.
  `--no-cache-counters` drops the second pass.
- **A quiet machine.** The 1-minute load average (`/proc/loadavg`) must be
  below `--max-load` (default: cores / 8) at the start, or the script stops.
  Before each cell, and so also after the builds (whose own load keeps the
  1-minute average high for a minute or two), the script waits until the
  load is below the threshold and the pinned CPU and its SMT siblings were
  at most `--max-cpu-busy` (default 10%) busy over one second, read from
  `/proc/stat`: the load average lags and covers the whole machine, the
  per-CPU share sees a job on the measured core. It gives up after
  `--settle` seconds (default 900) and exits nonzero, after writing the
  report for the cells already measured. `--force` measures
  without waiting. The load is read before every process; each result
  carries the highest load seen during it, and a cell measured above
  either threshold is marked BUSY. Instruction counts survive load; ns/op,
  cycles and cache misses do not.
- **Checksums agree.** Every process prints its checksum; all columns of a
  cell must print the same one, and each program the same one in every
  process. A row whose result is the library's own hash
  (`kairo_checksum = false` in ops.toml) leaves the Kairo columns out of
  the comparison. A disagreement is marked in the report and the script
  exits nonzero.
- **Failures are failures.** A process that exits nonzero ends its
  column for that cell. The column keeps the runs before the failure in
  its cell table, the summary row says "failed after n of N runs", and the
  script exits nonzero at the end.

## The report

`--out` (default `out/lib/`, which git ignores) holds `bin/`, `results.json` (every raw count
of every process, its load, and the derived figures) and `report.md`:

- two summary tables, one line per cell: Kairo (and Kairo before), the best
  other column per metric (fewest ns, instructions, cycles, branch misses,
  L1d and last-level misses) and the margin, ahead, tied or behind. Margin
  is how much less (+) or more (-) Kairo spends than that column, as a
  share of its figure. A counter within 0.5% is tied (two figures both
  below 0.01 per operation also tie); ns/op is tied when the min..max
  ranges of the two columns' runs overlap.
  A column whose checksum disagrees with the majority, that printed two
  checksums, or that failed partway is never the best other column: it is
  shown in the cell's table and named in the summary row.
- one table per cell: every column against every figure, with the ns
  spread, the number of runs and the load.

## Running

    python3 lib_bench.py                                   everything
    python3 lib_bench.py --cells slice.binary_search:1024,alloc.pair:16
    python3 lib_bench.py --rows '^map\.' --columns kairo,clang,kcc,rust
    python3 lib_bench.py --kairo-before <old tree>/bin/kairo
    python3 lib_bench.py --runs 3 --min-ms 20 --k 3 --force   a quick look on a busy machine
    python3 lib_bench.py --report-only                     report.md again from results.json

`--cells` takes `id:size` pairs (`id` alone for every size); only the
groups those cells need are built. Cells come from the programs themselves
(`<program> list`), in ops.toml's order; rows ops.toml does not list (the
`alloc` group) follow, labelled by id. Builds run `--jobs` at a time
(default 4).
