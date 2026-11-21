# Hash map and set rows (ops.toml, group "map"): std/tables Table and
# std/sets HashSet. A row without a suffix hashes with std/hashes (the key's
# own `hash`); a `_fast` row hashes with bench.nim's fast hasher, which the
# idiomatic way gives a table: a distinct key type with its own `hash`.
import std/[hashes, sets, tables]
import bench

type
  FastKey = distinct uint64
  FastStr = distinct string

proc `==`(a, b: FastKey): bool {.borrow.}
proc hash(k: FastKey): Hash {.inline.} = cast[Hash](fastHashU64(uint64(k)))
proc `==`(a, b: FastStr): bool {.borrow.}
proc hash(s: FastStr): Hash {.inline.} =
  let str = string(s)
  cast[Hash](fastHashBytes(cast[pointer](cstring(str)), str.len))

# A bijection on u64, so the "random" keys are distinct.
proc scramble(i: uint64): uint64 {.inline.} = i * Seed

# K is uint64 (the std hash) or FastKey; K(x) is the identity conversion for
# the first and the wrapping one for the second.
proc mapInsert[K](n: uint64, sequential: bool) =
  var m: Table[K, uint64]
  begin(n)
  while next():
    m = initTable[K, uint64]()
    tic()
    for i in 0'u64 ..< n:
      m[K(if sequential: i else: scramble(i))] = i
    toc(uint64(m.len))
  endRow()
  sinkPtr(addr m)

proc lookup[K](n: uint64, hit: bool) =
  let ops = 1'u64 shl 20
  var m = initTable[K, uint64](int(n))
  for i in 0'u64 ..< n:
    m[K(scramble(i))] = i
  begin(ops)
  while next():
    var rng = newRng()
    var acc = 0'u64
    tic()
    for i in 0'u64 ..< ops:
      let j = rng.below(n)
      acc += m.getOrDefault(K(scramble(if hit: j else: j + n)), 7)
    toc(acc)
  endRow()

proc churn[K](n: uint64) =
  let ops = 1'u64 shl 20
  var m: Table[K, uint64]
  for i in 0'u64 ..< n:
    m[K(scramble(i))] = i
  var nxt = n
  begin(ops)
  while next():
    tic()
    for i in 0'u64 ..< ops:
      m.del(K(scramble(nxt - n)))
      m[K(scramble(nxt))] = nxt
      inc nxt
    toc(uint64(m.len))
  endRow()

proc iterate(n: uint64) =
  let passes = 4'u64
  var m: Table[uint64, uint64]
  for i in 0'u64 ..< n:
    m[scramble(i)] = i
  begin(n * passes)
  while next():
    var acc = 0'u64
    tic()
    for p in 0'u64 ..< passes:
      sinkPtr(addr m)
      for v in m.values: acc += v
    toc(acc)
  endRow()

proc stringKeys(n: uint64, len: uint64): seq[string] =
  var rng = newRng()
  result = newSeq[string](int(n))
  for k in result.mitems: k = rng.letters(int(len), 26)

proc strInsert(len: uint64) =
  let n = 100000'u64
  let keys = stringKeys(n, len)
  var m: Table[string, uint64]
  begin(n)
  while next():
    m = initTable[string, uint64]()
    tic()
    for i in 0'u64 ..< n:
      m[keys[int(i)]] = i
    toc(uint64(m.len))
  endRow()
  sinkPtr(addr m)

proc strLookup[K](len: uint64) =
  let n = 100000'u64
  let ops = 1'u64 shl 18
  let keys = stringKeys(n, len)
  var m: Table[K, uint64]
  for i in 0'u64 ..< n:
    m[K(keys[int(i)])] = i
  begin(ops)
  while next():
    var rng = newRng()
    var acc = 0'u64
    tic()
    for i in 0'u64 ..< ops:
      acc += m.getOrDefault(K(keys[int(rng.below(n))]), 7)
    toc(acc)
  endRow()

proc copyMap(n: uint64) =
  var m: Table[uint64, uint64]
  for i in 0'u64 ..< n:
    m[scramble(i)] = i
  var c: Table[uint64, uint64]
  begin(n)
  while next():
    c = initTable[uint64, uint64]()
    tic()
    c = m
    toc(uint64(c.len))
  endRow()
  sinkPtr(addr c)

proc setInsert(n: uint64) =
  var s: HashSet[uint64]
  begin(n)
  while next():
    s = initHashSet[uint64]()
    tic()
    for i in 0'u64 ..< n:
      s.incl(scramble(i))
    toc(uint64(s.len))
  endRow()
  sinkPtr(addr s)

proc setContains(n: uint64) =
  let ops = 1'u64 shl 20
  var s: HashSet[uint64]
  for i in 0'u64 ..< n:
    s.incl(scramble(i))
  begin(ops)
  while next():
    var rng = newRng()
    var acc = 0'u64
    tic()
    for i in 0'u64 ..< ops:
      acc += uint64(ord(scramble(rng.below(2 * n)) in s))
    toc(acc)
  endRow()

init()
if want("map.insert_seq", 1000000): mapInsert[uint64](1000000, true)
if want("map.insert_rand", 1000000): mapInsert[uint64](1000000, false)
if want("map.insert_rand_fast", 1000000): mapInsert[FastKey](1000000, false)
for n in [1000'u64, 100000, 10000000]:
  if want("map.lookup_hit", n): lookup[uint64](n, true)
  if want("map.lookup_hit_fast", n): lookup[FastKey](n, true)
  if want("map.lookup_miss", n): lookup[uint64](n, false)
  if want("map.lookup_miss_fast", n): lookup[FastKey](n, false)
if want("map.churn", 100000): churn[uint64](100000)
if want("map.churn_fast", 100000): churn[FastKey](100000)
if want("map.iterate", 1000000): iterate(1000000)
for n in [8'u64, 32]:
  if want("map.str_insert", n): strInsert(n)
  if want("map.str_lookup", n): strLookup[string](n)
  if want("map.str_lookup_fast", n): strLookup[FastStr](n)
if want("map.copy", 1000000): copyMap(1000000)
if want("set.insert_rand", 1000000): setInsert(1000000)
if want("set.contains", 100000): setContains(100000)
