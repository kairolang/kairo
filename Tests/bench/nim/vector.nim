# Vector rows (ops.toml, group "vector"): seq[T].
import std/strutils
import bench

proc u64(x: int32): uint64 {.inline.} = cast[uint64](int64(x))

proc pushI32(n: uint64, reserve: bool) =
  var v: seq[int32]
  begin(n)
  while next():
    v = @[]
    tic()
    if reserve: v = newSeqOfCap[int32](int(n))
    for i in 0'u64 ..< n:
      v.add(int32(i))
    toc(uint64(v.len) + u64(v[int(n) - 1]))
  endRow()
  sinkPtr(addr v)

proc pushString(len: uint64) =
  let n = 1000000'u64
  let src = repeat('k', int(len))
  var v: seq[string]
  begin(n)
  while next():
    v = @[]
    tic()
    for i in 0'u64 ..< n:
      v.add(src[0 ..< int(opaque(len))])
    toc(uint64(v.len) + uint64(v[int(n) - 1].len))
  endRow()
  sinkPtr(addr v)

proc iterSum(n: uint64) =
  let passes = 10000000'u64 div n
  var rng = newRng()
  var v = newSeq[int32](int(n))
  for x in v.mitems: x = cast[int32](rng.next() and 0xFFFFFFFF'u64)
  begin(n * passes)
  while next():
    var sum = 0'i64
    tic()
    for p in 0'u64 ..< passes:
      sinkPtr(addr v[0])
      for x in v: sum += int64(x)
    toc(cast[uint64](sum))
  endRow()

proc insertFront(n: uint64) =
  var v: seq[int32]
  begin(n)
  while next():
    v = @[]
    tic()
    for i in 0'u64 ..< n:
      v.insert(int32(i), 0)
    toc(uint64(v.len) + u64(v[0]))
  endRow()
  sinkPtr(addr v)

proc createDestroy(elements: uint64) =
  let ops = 1000000'u64
  begin(ops)
  while next():
    var acc = 0'u64
    tic()
    for i in 0'u64 ..< ops:
      var v: seq[int32]
      if elements != 0: v.add(int32(opaque(i)))
      sinkPtr(addr v)
      acc += uint64(v.len)
    toc(acc)
  endRow()

# seq.del(i) is swap_remove: it moves the last element into slot i.
proc swapRemove(n: uint64) =
  var v: seq[int32]
  begin(n)
  while next():
    v.setLen(int(n))
    for i in 0 ..< int(n): v[i] = int32(i)
    var rng = newRng()
    var acc = 0'u64
    tic()
    while v.len != 0:
      let i = int(rng.below(uint64(v.len)))
      acc = acc * 31 + u64(v[i])
      v.del(i)
    toc(acc)
  endRow()

init()
if want("vector.push_i32", 10000000): pushI32(10000000, false)
if want("vector.push_i32_reserved", 10000000): pushI32(10000000, true)
# A Kairo-only row: push through a vector variant that keeps its capacity inline.
if want("vector.push_i32_cap24", 10000000): skip()
for n in [8'u64, 32]:
  if want("vector.push_string", n): pushString(n)
for n in [10000'u64, 10000000]:
  if want("vector.iter_sum", n): iterSum(n)
if want("vector.insert_front", 10000): insertFront(10000)
for n in [0'u64, 1]:
  if want("vector.create_destroy", n): createDestroy(n)
if want("vector.swap_remove", 1000000): swapRemove(1000000)
