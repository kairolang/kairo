## The measuring protocol of the builtin-library benchmarks in Nim: the same
## rules, output and inputs as cpp/bench.h, which documents them. Each program
## in this directory imports this module.
##
## A row is written as a loop:
##
##   if want("vector.push_i32", n):
##     begin(n)
##     while next():
##       <untimed setup>
##       tic()
##       <the workload>
##       toc(checksum)
##     endRow()
import std/[monotimes, os, strutils]

# --- the optimizer barrier ---------------------------------------------------

# Nim has no black_box; these are the same inline-asm barriers as
# cpp/bench.h's, emitted into the generated C.

## The value is treated as read by something the optimizer cannot see.
proc sink*(v: uint64) {.inline.} =
  {.emit: "__asm__ volatile(\"\" : : \"r,m\"(`v`) : \"memory\");".}

proc sinkPtr*(p: pointer) {.inline.} =
  {.emit: "__asm__ volatile(\"\" : : \"r,m\"(`p`) : \"memory\");".}

## The value comes back as one the optimizer knows nothing about.
proc opaque*(v: uint64): uint64 {.inline.} =
  result = v
  {.emit: "__asm__ volatile(\"\" : \"+r,m\"(`result`) : : \"memory\");".}

# --- selection and the repetition loop ---------------------------------------

type BenchState = object
  wantId: string      # "list", "all" or a row id
  anySize: bool
  wantSize: uint64
  minTotalNs: uint64
  fixedReps: uint64   # 0 = time-driven
  id: string
  size, ops, reps, minNs, totalNs, check: uint64
  t0: int64
  warm: bool

var st: BenchState

proc num(s: string, d: uint64): uint64 =
  if s.len == 0: d else: uint64(parseBiggestUInt(s))

## `prog <id|all|list> [size] [--min-ms=N] [--reps=K]`, or the same four from
## BENCH_ROW, BENCH_SIZE, BENCH_MIN_MS and BENCH_REPS.
proc init*() =
  var id = getEnv("BENCH_ROW", "list")
  var size = getEnv("BENCH_SIZE")
  var minMs = getEnv("BENCH_MIN_MS")
  var reps = getEnv("BENCH_REPS")
  var pos = 0
  for a in commandLineParams():
    if a.startsWith("--min-ms="): minMs = a[9 .. ^1]
    elif a.startsWith("--reps="): reps = a[7 .. ^1]
    elif pos == 0:
      id = a
      inc pos
    else: size = a
  st.wantId = id
  st.anySize = size.len == 0
  st.wantSize = if st.anySize: 0'u64 else: num(size, 0)
  st.minTotalNs = num(minMs, 200) * 1_000_000'u64
  st.fixedReps = num(reps, 0)

## True when the row at this size is to run now. In list mode it prints the
## pair and answers false.
proc want*(id: string, size: uint64): bool =
  if st.wantId == "list":
    echo id, ",", size
    return false
  if st.wantId != "all" and st.wantId != id: return false
  if not st.anySize and st.wantSize != size: return false
  st.id = id
  st.size = size
  true

proc begin*(opsPerRep: uint64) =
  st.ops = opsPerRep
  st.reps = 0
  st.minNs = high(uint64)
  st.totalNs = 0
  st.check = 0
  st.warm = false

proc next*(): bool =
  if not st.warm: return true
  if st.fixedReps != 0: return st.reps < st.fixedReps
  st.reps < 3 or (st.totalNs < st.minTotalNs and st.reps < 100_000_000'u64)

proc tic*() {.inline.} =
  st.t0 = ticks(getMonoTime())

proc toc*(check: uint64) {.inline.} =
  let dt = uint64(ticks(getMonoTime()) - st.t0)
  st.check = check
  if not st.warm:
    st.warm = true
    return
  st.reps += 1
  st.totalNs += dt
  if dt < st.minNs: st.minNs = dt

proc endRow*() =
  let perOp = formatFloat(float64(st.minNs) / float64(st.ops), ffDecimal, 4)
  echo st.id, ",", st.size, ",", perOp, ",", st.reps
  stdout.flushFile
  stderr.writeLine "check,", st.id, ",", st.size, ",", toHex(st.check, 16).toLowerAscii, ",", st.ops

## A row this program cannot run: the cell stays empty in the report.
proc skip*() =
  echo st.id, ",", st.size, ",nan,0"
  stdout.flushFile

# --- the shared inputs -------------------------------------------------------

## xorshift64 (13, 7, 17), seeded alike in every language.
const Seed* = 0x9E3779B97F4A7C15'u64
type Rng* = object
  s*: uint64

proc newRng*(): Rng = Rng(s: Seed)

proc next*(r: var Rng): uint64 {.inline.} =
  r.s = r.s xor (r.s shl 13)
  r.s = r.s xor (r.s shr 7)
  r.s = r.s xor (r.s shl 17)
  r.s

## Uniform in [0, n) for n < 2^32, with no division.
proc below*(r: var Rng, n: uint64): uint64 {.inline.} =
  ((r.next() shr 32) * n) shr 32

proc letters*(r: var Rng, len: int, alphabet: uint64): string =
  result = newString(len)
  for i in 0 ..< len:
    result[i] = char(ord('a') + int(r.below(alphabet)))

# --- the fast hasher of the rows that name one --------------------------------

const K0* = 0x2D358DCCAA6C78A5'u64
const K1* = 0x8BB84B93962EACC9'u64

## 64x64 -> 128 bit multiply folded to 64 bits. The standard library has no
## 128-bit integer, so this is the C compiler's.
proc fold*(a, b: uint64): uint64 {.inline.} =
  {.emit: ["unsigned __int128 m_ = (unsigned __int128)", a, " * ", b, "; ",
           result, " = (NU64)m_ ^ (NU64)(m_ >> 64);"].}

proc read64(p: ptr UncheckedArray[byte], off: int): uint64 {.inline.} =
  copyMem(addr result, addr p[off], 8)

proc fastHashU64*(x: uint64): uint64 {.inline.} = fold(x xor K0, K1)

proc fastHashBytes*(data: pointer, length: int): uint64 =
  let p = cast[ptr UncheckedArray[byte]](data)
  var len = length
  var off = 0
  var h = K0 xor uint64(len)
  if len >= 32:
    var a = h
    var b = h
    while true:
      a = fold(read64(p, off) xor K0, read64(p, off + 8) xor a)
      b = fold(read64(p, off + 16) xor K1, read64(p, off + 24) xor b)
      off += 32
      len -= 32
      if len < 32: break
    h = a xor b
  while len >= 8:
    h = fold(h xor read64(p, off), K1)
    off += 8
    len -= 8
  if len != 0:
    var w = 0'u64
    copyMem(addr w, addr p[off], len)
    h = fold(h xor w, K1)
  fold(h, K0)
