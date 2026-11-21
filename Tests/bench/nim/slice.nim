# Slice rows (ops.toml, group "slice"): std/algorithm over seq storage.
# Nim's std has one sort, a stable merge sort, so the `unstable` rows run the
# same `sort` as the `stable` rows: there is no unstable sort to pair with
# std::sort / sort_unstable.
import std/algorithm
import bench

type Wide = object
  key: uint64
  pad: array[7, uint64]

proc make(rng: var Rng, i: uint64, x: var int32) = x = cast[int32](rng.next())
proc make(rng: var Rng, i: uint64, x: var uint64) = x = rng.next()
proc make(rng: var Rng, i: uint64, x: var string) = x = rng.letters(16, 26)
proc make(rng: var Rng, i: uint64, x: var Wide) =
  x.key = rng.next()
  for p in x.pad.mitems: p = i

proc digest(x: int32): uint64 = uint64(cast[uint32](x))
proc digest(x: uint64): uint64 = x
proc digest(x: string): uint64 = fastHashBytes(cast[pointer](cstring(x)), x.len)
proc digest(x: Wide): uint64 = x.key xor x.pad[0]

proc cmpWide(a, b: Wide): int = cmp(a.key, b.key)

proc sortRow[T](n: uint64) =
  var rng = newRng()
  var input = newSeq[T](int(n))
  for i in 0 ..< int(n): make(rng, uint64(i), input[i])
  var work: seq[T]
  begin(n)
  while next():
    work = input
    tic()
    when T is Wide: work.sort(cmpWide)
    else: work.sort()
    let m = int(n)
    toc(digest(work[0]) xor (digest(work[m div 2]) * 3) xor (digest(work[m - 1]) * 5))
  endRow()

proc binarySearchRow(n: uint64) =
  let ops = 1'u64 shl 16
  var a = newSeq[uint64](int(n))
  for i in 0 ..< int(n): a[i] = 3 * uint64(i) + 1
  begin(ops)
  while next():
    var rng = newRng()
    var acc = 0'u64
    tic()
    for i in 0'u64 ..< ops:
      let q = rng.below(3 * n)
      let at = a.lowerBound(q)
      if at < a.len and a[at] == q: acc += uint64(at)
      else: acc += 1'u64 shl 40
    toc(acc)
  endRow()

proc reverseRow(n: uint64) =
  let passes = ((1'u64 shl 22) div n) or 1
  var a = newSeq[uint64](int(n))
  for i in 0 ..< int(n): a[i] = uint64(i)
  begin(n * passes)
  while next():
    tic()
    for p in 0'u64 ..< passes:
      sinkPtr(addr a[0])
      a.reverse()
    toc(a[0] + a[int(n) - 1])
  endRow()

proc fillRow(n: uint64) =
  let passes = (1'u64 shl 22) div n
  var a = newSeq[uint64](int(n))
  begin(n * passes)
  while next():
    tic()
    for p in 0'u64 ..< passes:
      a.fill(opaque(p))
      sinkPtr(addr a[0])
    toc(a[0] + a[int(n) - 1])
  endRow()

init()
const n = 1000000'u64
if want("slice.sort_unstable_i32", n): sortRow[int32](n)
if want("slice.sort_unstable_u64", n): sortRow[uint64](n)
if want("slice.sort_unstable_string", n): sortRow[string](n)
if want("slice.sort_unstable_struct64", n): sortRow[Wide](n)
if want("slice.sort_stable_i32", n): sortRow[int32](n)
if want("slice.sort_stable_u64", n): sortRow[uint64](n)
if want("slice.sort_stable_string", n): sortRow[string](n)
if want("slice.sort_stable_struct64", n): sortRow[Wide](n)
for m in [1024'u64, 10000000]:
  if want("slice.binary_search", m): binarySearchRow(m)
for m in [4096'u64, 1000000]:
  if want("slice.reverse", m): reverseRow(m)
for m in [4096'u64, 1000000]:
  if want("slice.fill", m): fillRow(m)
