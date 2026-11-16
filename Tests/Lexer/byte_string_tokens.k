// `b"..."` is one string token of kind b. The prefix is exactly a `b` (or
// `B`) touching the opening quote, with no name character before it: a
// longer name, a `b` with a space after it, a `b` before a comma and a `b`
// before a character literal are the name `b`.

var plain = b"ab\x00\xff"
var upper = B"x"
var chain = b"ab" b"cd"
var triple = b"""a"b"""
var name_ab = ab"x"
var name_sp = b "x"
var call = f(b, "x")
var chr = b'x'

// --- lit wiring ---
// RUN: { %kairo %s --syntax-only --print-tokens 2>/dev/null || true; } | %FileCheck %s
// CHECK:      identifier 'plain'
// CHECK-NEXT: = '='
// CHECK-NEXT: string '"ab\x00\xff"'
// CHECK-NEXT: `- string "ab\x00\xff"   kind=b interp-exprs=0{{$}}
// CHECK:      identifier 'upper'
// CHECK-NEXT: = '='
// CHECK-NEXT: string '"x"'
// CHECK-NEXT: `- string "x"   kind=b interp-exprs=0{{$}}
// CHECK:      identifier 'chain'
// CHECK-NEXT: = '='
// CHECK-NEXT: string '"ab"'
// CHECK-NEXT: `- string "ab"   kind=b interp-exprs=0 next={{[0-9]+}}
// CHECK-NEXT: new line
// CHECK:      identifier 'triple'
// CHECK-NEXT: = '='
// CHECK-NEXT: string '"a"b"'
// CHECK-NEXT: `- string "a"b"   kind=b interp-exprs=0{{$}}
// CHECK:      identifier 'name_ab'
// CHECK-NEXT: = '='
// CHECK-NEXT: identifier 'ab'
// CHECK-NEXT: string '"x"'
// CHECK-NEXT: `- string "x"   kind=none interp-exprs=0{{$}}
// CHECK:      identifier 'name_sp'
// CHECK-NEXT: = '='
// CHECK-NEXT: identifier 'b'
// CHECK-NEXT: string '"x"'
// CHECK-NEXT: `- string "x"   kind=none interp-exprs=0{{$}}
// CHECK:      identifier 'call'
// CHECK-NEXT: = '='
// CHECK-NEXT: identifier 'f'
// CHECK-NEXT: ( '('
// CHECK-NEXT: identifier 'b'
// CHECK-NEXT: , ','
// CHECK-NEXT: string '"x"'
// CHECK-NEXT: `- string "x"   kind=none interp-exprs=0{{$}}
// CHECK:      identifier 'chr'
// CHECK-NEXT: = '='
// CHECK-NEXT: identifier 'b'
// CHECK-NEXT: character ''x''
