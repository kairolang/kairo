# Allocation rows (ops.toml, group "alloc"): system.alloc / realloc /
# dealloc, and a `ref object` (freed by ORC) for the object rows.
import bench

type Bytes = ptr UncheckedArray[byte]

proc pair(size: uint64) =
  let ops = if size > 65536: 2000'u64 else: 200000'u64
  begin(ops)
  while next():
    var acc = 0'u64
    tic()
    for i in 0'u64 ..< ops:
      let n = int(opaque(size))
      let p = cast[Bytes](alloc(n))
      p[0] = byte(i and 0xFF)
      sinkPtr(p)
      acc += uint64(p[0])
      dealloc(p)
    toc(acc)
  endRow()

type
  Obj16 = ref object
    a, b: uint64
  Obj64 = ref object
    a, b: uint64
    pad: array[6, uint64]

template objectRow(T: typedesc) =
  let ops = 200000'u64
  begin(ops)
  while next():
    var acc = 0'u64
    tic()
    for i in 0'u64 ..< ops:
      let p = T(a: i, b: 2)
      sinkPtr(cast[pointer](p))
      acc += p.a + p.b
    toc(acc)
  endRow()

proc batch(size: uint64) =
  let live = 1024
  let rounds = 200'u64
  var slot: array[1024, pointer]
  begin(uint64(live) * rounds)
  while next():
    var acc = 0'u64
    tic()
    for r in 0'u64 ..< rounds:
      let n = int(opaque(size))
      for k in 0 ..< live:
        let p = cast[Bytes](alloc(n))
        p[0] = byte(k and 0xFF)
        slot[k] = p
      sinkPtr(addr slot[0])
      for k in 0 ..< live:
        acc += uint64(cast[Bytes](slot[k])[0])
        dealloc(slot[k])
    toc(acc)
  endRow()

proc grow(size: uint64) =
  let chains = 500'u64
  var steps = 0'u64
  var m = 16'u64
  while m < size:
    inc steps
    m *= 2
  begin(chains * steps)
  while next():
    var acc = 0'u64
    tic()
    for c in 0'u64 ..< chains:
      # 16 bytes, as a value the optimizer knows nothing about.
      var n = 16 + int(opaque(c) shr 60)
      var p = cast[Bytes](alloc(n))
      p[0] = 1
      while uint64(n) < size:
        p = cast[Bytes](realloc(p, n * 2))
        p[n] = 1
        sinkPtr(p)
        acc += uint64(p[0]) + uint64(p[n])
        n *= 2
      dealloc(p)
    toc(acc)
  endRow()

init()
for n in [16'u64, 256, 4096, 1048576]:
  if want("alloc.pair", n): pair(n)
if want("alloc.object", 16): objectRow(Obj16)
if want("alloc.object", 64): objectRow(Obj64)
for n in [16'u64, 256]:
  if want("alloc.batch", n): batch(n)
if want("alloc.grow", 1048576): grow(1048576)
