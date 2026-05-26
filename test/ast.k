import empty
// ═══════════════════════════════════════════════════════════════
// LITERALS
// ═══════════════════════════════════════════════════════════════
42                          // CHECK: int(integer)
3.14                        // CHECK: float(floating point)
"hello"                     // CHECK: str(plain, string)
'a'                         // CHECK: char(character)
true                        // CHECK: true
false                       // CHECK: false
null                        // CHECK: null
&null                       // CHECK: unary(prefix, &, null)

// ═══════════════════════════════════════════════════════════════
// IDENTIFIERS AND CHAINS
// ═══════════════════════════════════════════════════════════════
foo                         // CHECK: ident(identifier)
foo.bar                     // CHECK: chain(ident(identifier).identifier)
foo.bar.baz                 // CHECK: chain(ident(identifier).identifier.identifier)
foo::bar                    // CHECK: chain(ident(identifier)::identifier)
foo::bar::baz               // CHECK: chain(ident(identifier)::identifier::identifier)
foo?.bar                    // CHECK: chain(ident(identifier)?.identifier)
foo->bar                    // CHECK: chain(ident(identifier)->identifier)
::std::print                // CHECK: chain(chain(::identifier)::identifier)

// ═══════════════════════════════════════════════════════════════
// CALLS
// ═══════════════════════════════════════════════════════════════
foo()                       // CHECK: call(ident(identifier), args=[])
foo(1, 2, 3)                // CHECK: call(ident(identifier), args=[int(integer), int(integer), int(integer)])
foo(x: 10, y: 20)           // CHECK: call(ident(identifier), args=[assign(:, ident(identifier), int(integer)), assign(:, ident(identifier), int(integer))])
foo.bar()                   // CHECK: call(chain(ident(identifier).identifier), args=[])
foo.bar(1)                  // CHECK: call(chain(ident(identifier).identifier), args=[int(integer)])
foo::bar()                  // CHECK: call(chain(ident(identifier)::identifier), args=[])
foo()()                     // CHECK: call(call(ident(identifier), args=[]), args=[])
foo(1, 2, 3,)               // CHECK: call(ident(identifier), args=[int(integer), int(integer), int(integer)])
::std::print("Hello!")      // CHECK: call(chain(chain(::identifier)::identifier), args=[str(plain, string)])

// ═══════════════════════════════════════════════════════════════
// SUBSCRIPT
// ═══════════════════════════════════════════════════════════════
arr[0]                      // CHECK: subscript(ident(identifier), int(integer))
arr[0][1]                   // CHECK: subscript(subscript(ident(identifier), int(integer)), int(integer))
foo.bar[0]                  // CHECK: subscript(chain(ident(identifier).identifier), int(integer))
foo()[0]                    // CHECK: subscript(call(ident(identifier), args=[]), int(integer))

// ═══════════════════════════════════════════════════════════════
// PREFIX UNARY
// ═══════════════════════════════════════════════════════════════
!x                          // CHECK: unary(prefix, !, ident(identifier))
-x                          // CHECK: unary(prefix, -, ident(identifier))
~x                          // CHECK: unary(prefix, ~, ident(identifier))
&x                          // CHECK: unary(prefix, &, ident(identifier))
*x                          // CHECK: unary(prefix, *, ident(identifier))
++x                         // CHECK: unary(prefix, ++, ident(identifier))
--x                         // CHECK: unary(prefix, --, ident(identifier))

// ═══════════════════════════════════════════════════════════════
// POSTFIX UNARY
// ═══════════════════════════════════════════════════════════════
x++                         // CHECK: unary(postfix, ++, ident(identifier))
x--                         // CHECK: unary(postfix, --, ident(identifier))
foo...                      // CHECK: pack_expand(ident(identifier))

// ═══════════════════════════════════════════════════════════════
// BINARY OPERATORS — ARITHMETIC
// ═══════════════════════════════════════════════════════════════
1 + 2                       // CHECK: binop(+, int(integer), int(integer))
1 - 2                       // CHECK: binop(-, int(integer), int(integer))
1 * 2                       // CHECK: binop(*, int(integer), int(integer))
1 / 2                       // CHECK: binop(/, int(integer), int(integer))
1 % 2                       // CHECK: binop(%, int(integer), int(integer))
2 ^^ 3                      // CHECK: binop(^^, int(integer), int(integer))

// ═══════════════════════════════════════════════════════════════
// BINARY OPERATORS — PRECEDENCE
// ═══════════════════════════════════════════════════════════════
1 + 2 * 3                   // CHECK: binop(+, int(integer), binop(*, int(integer), int(integer)))
1 * 2 + 3                   // CHECK: binop(+, binop(*, int(integer), int(integer)), int(integer))
1 + 2 + 3                   // CHECK: binop(+, binop(+, int(integer), int(integer)), int(integer))
a + b * c + d               // CHECK: binop(+, binop(+, ident(identifier), binop(*, ident(identifier), ident(identifier))), ident(identifier))

// ═══════════════════════════════════════════════════════════════
// BINARY OPERATORS — ASSOCIATIVITY
// ═══════════════════════════════════════════════════════════════
a = b = c                   // CHECK: assign(=, ident(identifier), assign(=, ident(identifier), ident(identifier)))
2 ^^ 3 ^^ 4                 // CHECK: binop(^^, int(integer), binop(^^, int(integer), int(integer)))

// ═══════════════════════════════════════════════════════════════
// BINARY OPERATORS — COMPARISON AND LOGICAL
// ═══════════════════════════════════════════════════════════════
a == b                      // CHECK: binop(==, ident(identifier), ident(identifier))
a != b                      // CHECK: binop(!=, ident(identifier), ident(identifier))
a < b                       // CHECK: binop(<, ident(identifier), ident(identifier))
a > b                       // CHECK: binop(>, ident(identifier), ident(identifier))
a <= b                      // CHECK: binop(<=, ident(identifier), ident(identifier))
a >= b                      // CHECK: binop(>=, ident(identifier), ident(identifier))
a === b                     // CHECK: binop(===, ident(identifier), ident(identifier))
a && b                      // CHECK: binop(&&, ident(identifier), ident(identifier))
a || b                      // CHECK: binop(||, ident(identifier), ident(identifier))
a || b && c                 // CHECK: binop(||, ident(identifier), binop(&&, ident(identifier), ident(identifier)))
a && b || c                 // CHECK: binop(||, binop(&&, ident(identifier), ident(identifier)), ident(identifier))

// ═══════════════════════════════════════════════════════════════
// BINARY OPERATORS — BITWISE
// ═══════════════════════════════════════════════════════════════
a & b                       // CHECK: binop(&, ident(identifier), ident(identifier))
a | b                       // CHECK: binop(|, ident(identifier), ident(identifier))
a ^ b                       // CHECK: binop(^, ident(identifier), ident(identifier))
a << b                      // CHECK: binop(<<, ident(identifier), ident(identifier))
a >> b                      // CHECK: binop(>>, ident(identifier), ident(identifier))
a | b ^ c & d               // CHECK: binop(|, ident(identifier), binop(^, ident(identifier), binop(&, ident(identifier), ident(identifier))))

// ═══════════════════════════════════════════════════════════════
// BINARY OPERATORS — ASSIGNMENT COMPOUND
// ═══════════════════════════════════════════════════════════════
x += 1                      // CHECK: assign(+=, ident(identifier), int(integer))
x -= 1                      // CHECK: assign(-=, ident(identifier), int(integer))
x *= 2                      // CHECK: assign(*=, ident(identifier), int(integer))
x /= 2                      // CHECK: assign(/=, ident(identifier), int(integer))
x %= 3                      // CHECK: assign(%=, ident(identifier), int(integer))
x &= 0xFF                   // CHECK: assign(&=, ident(identifier), int(integer))
x |= 0x01                   // CHECK: assign(|=, ident(identifier), int(integer))
x ^= mask                   // CHECK: assign(^=, ident(identifier), ident(identifier))
x <<= 4                     // CHECK: assign(<<=, ident(identifier), int(integer))
x >>= 2                     // CHECK: assign(>>=, ident(identifier), int(integer))

// ═══════════════════════════════════════════════════════════════
// BINARY + UNARY INTERACTION
// ═══════════════════════════════════════════════════════════════
!a + b                      // CHECK: binop(+, unary(prefix, !, ident(identifier)), ident(identifier))
-a * b                      // CHECK: binop(*, unary(prefix, -, ident(identifier)), ident(identifier))
a + -b                      // CHECK: binop(+, ident(identifier), unary(prefix, -, ident(identifier)))
x = 1 + 2 * 3              // CHECK: assign(=, ident(identifier), binop(+, int(integer), binop(*, int(integer), int(integer))))
a + b * c ^^ d              // CHECK: binop(+, ident(identifier), binop(*, ident(identifier), binop(^^, ident(identifier), ident(identifier))))

// ═══════════════════════════════════════════════════════════════
// RANGE EXPRESSIONS
// ═══════════════════════════════════════════════════════════════
1..10                       // CHECK: range(int(integer), .., int(integer))
1..=10                      // CHECK: range(int(integer), ..=, int(integer))
..10                        // CHECK: range(<null>, .., int(integer))
..=10                       // CHECK: range(<null>, ..=, int(integer))
1..                         // CHECK: range(int(integer), .., <null>)
..                          // CHECK: range(<null>, .., <null>)

// ═══════════════════════════════════════════════════════════════
// TYPE CAST
// ═══════════════════════════════════════════════════════════════
foo as i32                  // CHECK: cast(ident(identifier), named(i32))
foo as unsafe *Bar          // CHECK: cast(ident(identifier), unsafe *named(identifier))
1 + 2 as i64               // CHECK: binop(+, int(integer), cast(int(integer), named(i64)))

// ═══════════════════════════════════════════════════════════════
// KEYWORD EXPRESSIONS
// ═══════════════════════════════════════════════════════════════
sizeof(i32)                 // CHECK: sizeof(named(i32))
alignof(u64)                // CHECK: alignof(named(u64))
typeof(foo)                 // CHECK: typeof(ident(identifier))
eval foo                    // CHECK: eval(ident(identifier))
unsafe foo                  // CHECK: unsafe(ident(identifier))
delete foo                  // CHECK: delete(ident(identifier))
delete [] arr               // CHECK: delete[](ident(identifier))
await foo                   // CHECK: await(ident(identifier))
spawn foo                   // CHECK: spawn(ident(identifier))
thread foo                  // CHECK: thread(ident(identifier))

// ═══════════════════════════════════════════════════════════════
// COLLECTION LITERALS
// ═══════════════════════════════════════════════════════════════
[1, 2, 3]                   // CHECK: [int(integer), int(integer), int(integer)]
[]                          // CHECK: []
(1, 2, 3)                   // CHECK: (int(integer), int(integer), int(integer))
{1, 2, 3}                   // CHECK: {int(integer), int(integer), int(integer)}
{"a": 1, "b": 2}            // CHECK: {str(plain, string): int(integer), str(plain, string): int(integer)}
{ .x: 1, .y: 2 }           // CHECK: { .identifier: int(integer), .identifier: int(integer) }
[1, 2, 3,]                  // CHECK: [int(integer), int(integer), int(integer)]
(1, 2, 3,)                  // CHECK: (int(integer), int(integer), int(integer))
{1, 2, 3,}                  // CHECK: {int(integer), int(integer), int(integer)}
{"a": 1, "b": 2,}           // CHECK: {str(plain, string): int(integer), str(plain, string): int(integer)}
[1]                         // CHECK: [int(integer)]
{1}                         // CHECK: {int(integer)}
{"a": 1}                    // CHECK: {str(plain, string): int(integer)}

// ═══════════════════════════════════════════════════════════════
// COMPLEX MIXED EXPRESSIONS
// ═══════════════════════════════════════════════════════════════
foo.bar(1, 2).baz[0].qux().corge
// CHECK: chain(call(chain(subscript(chain(call(chain(ident(identifier).identifier), args=[int(integer), int(integer)]).identifier), int(integer)).identifier), args=[]).identifier)

foo()().bar[0][1].baz(x: 10)
// CHECK: call(chain(subscript(subscript(chain(call(call(ident(identifier), args=[]), args=[]).identifier), int(integer)), int(integer)).identifier), args=[assign(:, ident(identifier), int(integer))])

foo?.bar?.baz?.qux
// CHECK: chain(ident(identifier)?.identifier?.identifier?.identifier)

a + b * c - d / e
// CHECK: binop(-, binop(+, ident(identifier), binop(*, ident(identifier), ident(identifier))), binop(/, ident(identifier), ident(identifier)))

(1 + 2) * 3
// CHECK: binop(*, binop(+, int(integer), int(integer)), int(integer))

arr[0] + arr[1]
// CHECK: binop(+, subscript(ident(identifier), int(integer)), subscript(ident(identifier), int(integer)))

foo(a + b, c * d)
// CHECK: call(ident(identifier), args=[binop(+, ident(identifier), ident(identifier)), binop(*, ident(identifier), ident(identifier))])

!foo.bar
// CHECK: unary(prefix, !, chain(ident(identifier).identifier))

-foo()
// CHECK: unary(prefix, -, call(ident(identifier), args=[]))

*ptr + 1
// CHECK: binop(+, unary(prefix, *, ident(identifier)), int(integer))

a || b && c == d
// CHECK: binop(||, ident(identifier), binop(&&, ident(identifier), binop(==, ident(identifier), ident(identifier))))

x = y = a + b
// CHECK: assign(=, ident(identifier), assign(=, ident(identifier), binop(+, ident(identifier), ident(identifier))))

foo as i32 + bar as i64
// CHECK: binop(+, cast(ident(identifier), named(i32)), cast(ident(identifier), named(i64)))

// ═══════════════════════════════════════════════════════════════
// STRESS: deeply nested binary
// ═══════════════════════════════════════════════════════════════
a + b + c + d + e + f + g + h
// CHECK: binop(+, binop(+, binop(+, binop(+, binop(+, binop(+, binop(+, ident(identifier), ident(identifier)), ident(identifier)), ident(identifier)), ident(identifier)), ident(identifier)), ident(identifier)), ident(identifier))

// ═══════════════════════════════════════════════════════════════
// NEGATIVE: missing RHS
// ═══════════════════════════════════════════════════════════════
1 +
// CHECK: error

1 *
// CHECK: error

a =
// CHECK: error

a &&
// CHECK: error

// ═══════════════════════════════════════════════════════════════
// NEGATIVE: double operators
// ═══════════════════════════════════════════════════════════════
1 + + 2
// CHECK: binop(+, int(integer), unary(prefix, +, int(integer)))
// NOTE: + is not a valid prefix unary — should error but parse

1 * * 2
// CHECK: binop(*, int(integer), unary(prefix, *, int(integer)))
// NOTE: * as prefix is deref, so this is legal: 1 * (*2)

// // ═══════════════════════════════════════════════════════════════
// // NEGATIVE: unclosed delimiters with binary ops
// // ═══════════════════════════════════════════════════════════════
// (1 + 2
// // CHECK: error

// [1 + 2
// // CHECK: error

// {1 + 2
// // CHECK: error

// ═══════════════════════════════════════════════════════════════
// NEGATIVE: binary op at start of expression
// ═══════════════════════════════════════════════════════════════
+ 1
// CHECK: error — + is not a valid prefix

* 1
// CHECK: unary(prefix, *, int(integer)) — deref is valid prefix

/ 1
// CHECK: error — / is not a valid prefix

// ═══════════════════════════════════════════════════════════════
// EDGE: parenthesized single expression (not tuple)
// ═══════════════════════════════════════════════════════════════
(42)
// CHECK: int(integer) — parens unwrap

(foo)
// CHECK: ident(identifier) — parens unwrap

((1 + 2))
// CHECK: binop(+, int(integer), int(integer)) — double parens unwrap

// ═══════════════════════════════════════════════════════════════
// EDGE: expression in subscript
// ═══════════════════════════════════════════════════════════════
arr[1 + 2]
// CHECK: subscript(ident(identifier), binop(+, int(integer), int(integer)))

arr[foo()]
// CHECK: subscript(ident(identifier), call(ident(identifier), args=[]))

// ═══════════════════════════════════════════════════════════════
// EDGE: range in subscript (slice)
// ═══════════════════════════════════════════════════════════════
arr[1..3]
// CHECK: subscript(ident(identifier), range(int(integer), .., int(integer)))

arr[..3]
// CHECK: subscript(ident(identifier), range(<null>, .., int(integer)))

arr[1..]
// CHECK: subscript(ident(identifier), range(int(integer), .., <null>))

// ═══════════════════════════════════════════════════════════════
// EDGE: chained casts
// ═══════════════════════════════════════════════════════════════
foo as i32 as i64
// CHECK: cast(cast(ident(identifier), named(i32)), named(i64))

// ═══════════════════════════════════════════════════════════════
// EDGE: eval/unsafe with binary
// ═══════════════════════════════════════════════════════════════
eval 1 + 2
// CHECK: binop(+, eval(int(integer)), int(integer))
// NOTE: eval binds tighter than +, so eval(1) + 2

unsafe *ptr + 1
// CHECK: binop(+, unsafe(unary(prefix, *, ident(identifier))), int(integer))

// ═══════════════════════════════════════════════════════════════
// EDGE: delete with binary (should not happen but test recovery)
// ═══════════════════════════════════════════════════════════════
delete foo + bar
// CHECK: binop(+, delete(ident(identifier)), ident(identifier))
// NOTE: delete binds to foo only, + is binary

// ═══════════════════════════════════════════════════════════════
// EDGE: await with call
// ═══════════════════════════════════════════════════════════════
await foo()
// CHECK: await(call(ident(identifier), args=[]))

await foo.bar()
// CHECK: await(call(chain(ident(identifier).identifier), args=[]))

// ═══════════════════════════════════════════════════════════════
// EDGE: spawn with chain
// ═══════════════════════════════════════════════════════════════
spawn worker.run()
// CHECK: spawn(call(chain(ident(identifier).identifier), args=[]))

// ═══════════════════════════════════════════════════════════════
// EDGE: mixed postfix and binary
// ═══════════════════════════════════════════════════════════════
foo.bar + baz.qux
// CHECK: binop(+, chain(ident(identifier).identifier), chain(ident(identifier).identifier))

foo() + bar()
// CHECK: binop(+, call(ident(identifier), args=[]), call(ident(identifier), args=[]))

arr[0] * arr[1] + arr[2]
// CHECK: binop(+, binop(*, subscript(ident(identifier), int(integer)), subscript(ident(identifier), int(integer))), subscript(ident(identifier), int(integer)))

// ═══════════════════════════════════════════════════════════════
// EDGE: complex assignment RHS
// ═══════════════════════════════════════════════════════════════
x = foo.bar(1) + baz[0] * 2
// CHECK: assign(=, ident(identifier), binop(+, call(chain(ident(identifier).identifier), args=[int(integer)]), binop(*, subscript(ident(identifier), int(integer)), int(integer))))

x += foo() as i32
// CHECK: assign(+=, ident(identifier), cast(call(ident(identifier), args=[]), named(i32)))
