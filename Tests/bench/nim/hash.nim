# Hasher rows (ops.toml, group "hash"). `_std` is std/hashes' `hash`, the one
# Table and HashSet use by default; `_fast` is bench.nim's fast hasher. A
# `_std` checksum counts the calls; a `_fast` checksum is the hashes
# themselves.
import std/hashes
import bench

proc u64Row(fast: bool) =
  let ops = 1'u64 shl 20
  begin(ops)
  while next():
    var acc = 0'u64
    tic()
    if fast:
      for i in 0'u64 ..< ops: acc += fastHashU64(opaque(i))
    else:
      for i in 0'u64 ..< ops: acc += cast[uint64](hash(opaque(i)))
    sink(acc)
    toc(if fast: acc else: ops)
  endRow()

proc bytesRow(len: uint64, fast: bool) =
  let keys = 256'u64
  let passes = (1'u64 shl 22) div (keys * len)
  var rng = newRng()
  var k = newSeq[string](int(keys))
  for s in k.mitems: s = rng.letters(int(len), 26)
  begin(keys * passes)
  while next():
    var acc = 0'u64
    tic()
    for p in 0'u64 ..< passes:
      sinkPtr(addr k[0])
      if fast:
        for s in k: acc += fastHashBytes(cast[pointer](cstring(s)), s.len)
      else:
        for s in k: acc += cast[uint64](hash(s))
    sink(acc)
    toc(if fast: acc else: keys * passes)
  endRow()

init()
if want("hash.u64_std", 8): u64Row(false)
if want("hash.u64_fast", 8): u64Row(true)
for n in [8'u64, 16, 64, 1024]:
  if want("hash.bytes_std", n): bytesRow(n, false)
  if want("hash.bytes_fast", n): bytesRow(n, true)
