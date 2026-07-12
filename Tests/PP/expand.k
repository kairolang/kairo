// SEPARATE:
macro list!(...xs) { [ xs... ] }

var l = list!()          // empty pack: expect `[ ]`, no stray `xs...`
var m = list!(1)
var n = list!(1, 2, 3)

// builtin arg pre-expansion (value-position builtins)
var c1 = count!(1, 2, 3)          // 3
var c2 = count!(rest!(1, 2, 3))   // rest! -> `2, 3` -> 2
var f1 = first!(rest!(1, 2, 3))   // 2
var i1 = butlast!(1, 2, 3)        // 1, 2

// paste! pastes to ONE identifier; args pre-expand first
macro getter!(name) { paste!(get_, name) }
var g = getter!(size)             // get_size
var g2 = paste!(get_, first!(alpha, beta))   // get_alpha

// stringify!/defined! stay RAW (quoting/name position)
var s = stringify!(rest!(1, 2))   // "rest!(1, 2)" spelling, NOT "2"
var d = defined!(list)            // 1

// pattern splat: replicate the parenthesized pattern per pack element
macro wrap_all!(...xs)  { [ (box(xs))... ] }        // [ box(1), box(2) ]
macro pair_up!(k, ...xs) { [ ((k, xs))... ] }       // parens for output: double them
var w = wrap_all!(1, 2)          // [ box(1), box(2) ]
var p = pair_up!(id, 7, 8)       // [ (id, 7), (id, 8) ]
var e = wrap_all!()              // [ ] empty pack consumes the pattern

// owned-text strings + re-lex round trip
var s2 = stringify!(a + b)        // "a + b" (source-backed, owned text set)
var u1 = unstringify!("1 + 2")    // tokens: 1 + 2 (offset fix: must NOT be garbage)
var fp = file!                    // owned-text string literal, real imm now
macro sfy!(x) { stringify!(x) }
var s3 = sfy!(foo + 1)            // "foo + 1" via substituted param tokens
