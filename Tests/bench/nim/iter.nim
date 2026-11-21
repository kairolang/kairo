# Iterator chain rows (ops.toml, group "iter"): std/sequtils, std/algorithm
# and the iterators of `system`, and beside each chain the loop a person would
# write by hand (`_loop`).
#
# Nim's std has no lazy map / take_while / reverse adapters. Where a lazy
# std iterator exists the chain uses it (enumerate_take: `pairs` over a
# slice). Elsewhere the chain is the eager sequtils / algorithm form, which
# allocates its intermediate seqs: map_filter_sum (mapIt + filterIt + foldl),
# rev_take_while_count (reversed copy + findIt) and collect_map (mapIt, which
# is one allocation like the twins' reserved collect).
import std/[algorithm, sequtils]
import bench

# Values in [-1000, 1000]: no sum below leaves i32.
proc input(n: uint64): seq[int32] =
  var rng = newRng()
  result = newSeq[int32](int(n))
  for x in result.mitems: x = int32(rng.below(2001)) - 1000

type Chain = enum MapFilterSum, EnumerateTake, RevTakeWhile, CollectMap

proc s64(x: int32): uint64 {.inline.} = cast[uint64](int64(x))

proc chain(which: Chain, v: seq[int32]): uint64 =
  case which
  of MapFilterSum:
    let sum = v.mapIt(it * 3).filterIt((it and 1) == 0).foldl(a + b, 0'i32)
    s64(sum)
  of EnumerateTake:
    var sum = 0'i64
    for i, x in v.toOpenArray(0, v.len div 2 - 1).pairs:
      sum += int64(i) * int64(x)
    cast[uint64](sum)
  of RevTakeWhile:
    let r = v.reversed
    let at = r.findIt(it == 5000)
    uint64(if at < 0: r.len else: at)
  of CollectMap:
    let o = v.mapIt(it * 3)
    sinkPtr(unsafeAddr o[0])
    uint64(o.len) + s64(o[^1])

proc byHand(which: Chain, v: seq[int32]): uint64 =
  let n = v.len
  case which
  of MapFilterSum:
    var sum = 0'i32
    for i in 0 ..< n:
      let x = v[i] * 3
      if (x and 1) == 0: sum += x
    s64(sum)
  of EnumerateTake:
    var sum = 0'i64
    for i in 0 ..< n div 2: sum += int64(i) * int64(v[i])
    cast[uint64](sum)
  of RevTakeWhile:
    var i = n
    while i != 0 and v[i - 1] != 5000: dec i
    uint64(n - i)
  of CollectMap:
    var o = newSeqOfCap[int32](n)
    for i in 0 ..< n: o.add(v[i] * 3)
    sinkPtr(addr o[0])
    uint64(o.len) + s64(o[n - 1])

proc run(which: Chain, hand: bool, n: uint64) =
  let passes = (1'u64 shl 22) div n
  let v = input(n)
  begin((if which == EnumerateTake: n div 2 else: n) * passes)
  while next():
    var acc = 0'u64
    tic()
    for p in 0'u64 ..< passes:
      sinkPtr(unsafeAddr v[0])
      acc += (if hand: byHand(which, v) else: chain(which, v))
    toc(acc)
  endRow()

init()
for n in [1000'u64, 1000000]:
  if want("iter.map_filter_sum", n): run(MapFilterSum, false, n)
  if want("iter.map_filter_sum_loop", n): run(MapFilterSum, true, n)
  if want("iter.enumerate_take", n): run(EnumerateTake, false, n)
  if want("iter.enumerate_take_loop", n): run(EnumerateTake, true, n)
  if want("iter.rev_take_while_count", n): run(RevTakeWhile, false, n)
  if want("iter.rev_take_while_count_loop", n): run(RevTakeWhile, true, n)
  if want("iter.collect_map", n): run(CollectMap, false, n)
  if want("iter.collect_map_loop", n): run(CollectMap, true, n)
