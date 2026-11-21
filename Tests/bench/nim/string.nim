# String rows (ops.toml, group "string"): Nim's string.
import std/[strutils, unicode]
import bench

proc data(s: string): pointer {.inline.} = cast[pointer](cstring(s))

proc createDestroy(len: uint64) =
  let ops = 200000'u64
  var rng = newRng()
  let src = rng.letters(int(len), 26)
  begin(ops)
  while next():
    var acc = 0'u64
    tic()
    for i in 0'u64 ..< ops:
      let s = src[0 ..< int(opaque(len))]
      sinkPtr(data(s))
      acc += uint64(s.len)
    toc(acc)
  endRow()

proc pushByte(n: uint64) =
  var s: string
  begin(n)
  while next():
    s = ""
    tic()
    for i in 0'u64 ..< n:
      s.add(char(ord('a') + int(i and 15)))
    toc(uint64(s.len) + uint64(ord(s[int(n) - 1])))
  endRow()
  sinkPtr(data(s))

proc appendLiteral(len: uint64) =
  let ops = 100000'u64
  var s: string
  begin(ops)
  while next():
    s = ""
    tic()
    if len == 4:
      for i in 0'u64 ..< ops: s.add("abcd")
    else:
      for i in 0'u64 ..< ops: s.add("hello, world")
    toc(uint64(s.len))
  endRow()
  sinkPtr(data(s))

proc findRow(n: uint64) =
  let ops = (1'u64 shl 22) div n
  var rng = newRng()
  var hay = rng.letters(int(n), 16)
  hay[int(n) - 1] = 'z'
  let needle = hay[int(n) - 8 ..< int(n)]
  begin(ops)
  while next():
    var acc = 0'u64
    tic()
    for i in 0'u64 ..< ops:
      sinkPtr(data(hay))
      sinkPtr(data(needle))
      acc += uint64(hay.find(needle))
    toc(acc)
  endRow()

proc eqRow(len: uint64) =
  let pairs = 1024
  let passes = 64'u64
  var rng = newRng()
  var a, b: seq[string]
  for i in 0 ..< pairs:
    a.add(rng.letters(int(len), 26))
    b.add(a[^1])
    if (i and 1) != 0: b[^1][int(len) - 1] = 'Z'
  begin(uint64(pairs) * passes)
  while next():
    var acc = 0'u64
    tic()
    for p in 0'u64 ..< passes:
      sinkPtr(addr a[0])
      sinkPtr(addr b[0])
      for i in 0 ..< pairs: acc += uint64(ord(a[i] == b[i]))
    toc(acc)
  endRow()

# UTF-8 text of exactly n bytes: seven in ten code points are one byte, two
# are two bytes (U+00C0..U+00FF), one is three (U+2080..U+20BF).
proc utf8Text(n: uint64): string =
  var rng = newRng()
  while uint64(result.len) + 3 <= n:
    let kind = rng.below(10)
    if kind < 7:
      result.add(char(ord('a') + int(rng.below(26))))
    elif kind < 9:
      result.add(char(0xC3))
      result.add(char(0x80 + int(rng.below(64))))
    else:
      result.add(char(0xE2))
      result.add(char(0x82))
      result.add(char(0x80 + int(rng.below(64))))
  while uint64(result.len) < n: result.add('x')

# unicode.runeLen is the standard code point count.
proc codepoints(n: uint64) =
  let passes = (1'u64 shl 22) div n
  let s = utf8Text(n)
  begin(n * passes)
  while next():
    var acc = 0'u64
    tic()
    for p in 0'u64 ..< passes:
      sinkPtr(data(s))
      acc += uint64(runeLen(s))
    toc(acc)
  endRow()

init()
for n in [0'u64, 8, 32, 256]:
  if want("string.create_destroy", n): createDestroy(n)
if want("string.push_byte", 1048576): pushByte(1048576)
for n in [4'u64, 12]:
  if want("string.append_literal", n): appendLiteral(n)
for n in [64'u64, 4096, 1048576]:
  if want("string.find", n): findRow(n)
for n in [8'u64, 16]:
  if want("string.eq", n): eqRow(n)
for n in [4096'u64, 1048576]:
  if want("string.codepoints", n): codepoints(n)
# The count is not stored by a Nim string: no counterpart to a cached read.
for n in [4096'u64, 1048576]:
  if want("string.codepoints_cached", n): skip()
