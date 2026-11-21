# Number text rows (ops.toml, group "num"): system.addInt / addFloat (the `$`
# text, appended to a string in place), strutils.parseBiggestUInt and
# strutils.parseFloat.
import std/strutils
import bench

const Count = 4096'u64
const Passes = 64'u64

proc integers(digits: uint64): seq[uint64] =
  var rng = newRng()
  result = newSeq[uint64](int(Count))
  for x in result.mitems:
    x = if digits == 4: rng.below(10000) else: rng.next()

# In [0, 10^6), with a full 53-bit significand.
proc doubles(): seq[float64] =
  var rng = newRng()
  result = newSeq[float64](int(Count))
  for x in result.mitems:
    x = float64(rng.next() shr 11) * (1.0 / 9007199254740992.0) * 1e6

proc toText[T](v: seq[T]) =
  var s: string
  begin(Count * Passes)
  while next():
    var acc = 0'u64
    tic()
    for p in 0'u64 ..< Passes:
      sinkPtr(unsafeAddr v[0])
      s.setLen(0)
      for x in v:
        when T is uint64: s.addInt(x)
        else: s.addFloat(x)
      acc += uint64(s.len)
    toc(acc)
  endRow()

proc textToU64(digits: uint64) =
  var text: seq[string]
  for x in integers(digits): text.add($x)
  begin(Count * Passes)
  while next():
    var acc = 0'u64
    tic()
    for p in 0'u64 ..< Passes:
      sinkPtr(unsafeAddr text[0])
      for t in text: acc += parseBiggestUInt(t)
    toc(acc)
  endRow()

proc textToF64() =
  var text: seq[string]
  for x in doubles(): text.add($x)
  begin(Count * Passes)
  while next():
    var acc = 0'u64
    tic()
    for p in 0'u64 ..< Passes:
      sinkPtr(unsafeAddr text[0])
      for t in text: acc += cast[uint64](parseFloat(t))
    toc(acc)
  endRow()

init()
for d in [4'u64, 20]:
  if want("num.u64_to_text", d): toText(integers(d))
  if want("num.text_to_u64", d): textToU64(d)
if want("num.f64_to_text", 17): toText(doubles())
if want("num.text_to_f64", 17): textToF64()
