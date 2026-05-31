// ============================================================================
//  StmtParse corpus  -- happy paths and negative paths
//
//  NOTE: anything that routes through parse_decl (plain `var x =`, C-style for
//  init, eval-block bodies) renders as <decl>/recovery while DeclParse is a
//  stub. Match patterns render as <pattern> until PatternParse lands. Those
//  are placeholder-limited, NOT misparses.
// ============================================================================

// ── expression statements ──────────────────────────────────────────────────
foo()
foo.bar.baz
a + b * c
x[0] = 42
obj->method(1, 2, 3)
foo()...
await getThing()
spawn worker()
sizeof(i32)
foo as i32                 // cast, NOT context binding (no var/const)
foo as unsafe *i32         // unsafe cast

// ── return / break / continue ───────────────────────────────────────────────
return
return 42
return foo() + bar()
break
break outer
continue
continue loop_label

// NEGATIVE: malformed return value
return +

// ── panic / yield ───────────────────────────────────────────────────────────
panic "something broke"
panic MyError { code: 5 }
yield 1
yield compute(x)

// NEGATIVE: missing operand
panic
yield

// ── assert (runtime + static) ────────────────────────────────────────────────
// assert x > 0
// assert x > 0, "x must be positive"
// assert static sizeof(i32) == 4
// assert static T::is_valid, "type check failed"

// NEGATIVE: missing condition
// assert
// assert static

// ── if / else-if / else ──────────────────────────────────────────────────────
// if x > 0 { foo() }
// if x > 0 { foo() } else { bar() }
// if x > 0 { a() } else if x < 0 { b() } else { c() }
// if cond { return 1 } else if other { return 2 } else if third { return 3 } else { return 0 }
// if (Foo { x: 1 }).valid { ok() }     // struct literal allowed inside parens

// // NEGATIVE: missing block
// if x > 0 foo()
// // NEGATIVE: missing condition
// if { foo() }
// // NEGATIVE: dangling else
// if x { a() } else

// ── while / loop ──────────────────────────────────────────────────────────────
while x < 10 { x += 1 }
while running { tick() }
loop { work() }
loop { if done { break } }

// NEGATIVE: missing block
while x < 10
// NEGATIVE: missing condition
while { foo() }

// // ── ranged for (real: bindings parse) ───────────────────────────────────────
// for var i in 0..10 { print(i) }
// for const x in items { use(x) }
// for var (k, v) in map { print(k) }
// for var (k, const v) in map { mutate(k) }
// for var (a, const b, _) in triples { foo(a, b) }
// for var *p in pointers { deref(p) }
// for var x? in maybes { check(x) }
// for var i in 0..=100 { sum += i }
// eval for var i in 0..4 { unroll(i) }

// NEGATIVE: missing `in`
for var i 0..10 { foo() }
// NEGATIVE: missing binding keyword (plain `i` not allowed)
for i in items { foo() }
// NEGATIVE: missing block
for var i in items
// NEGATIVE: empty binding list
for var () in items { foo() }

// ── C-style for (init is <decl>, placeholder) ───────────────────────────────
for var i = 0; i < 10; i += 1 { foo() }
for var i = 0, j = n; i < j; i += 1 { swap(i, j) }
eval for var k = 0; k < 4; k += 1 { unroll(k) }

// NEGATIVE: missing semicolons
for var i = 0 i < 10 i += 1 { foo() }
// NEGATIVE: missing update
for var i = 0; i < 10; { foo() }

// ── match (patterns are <pattern>, placeholder) ─────────────────────────────
match x {
    case 1 { one() }
    case 2, 3, 4 { few() }
    default { many() }
}
match result {
    case .Ok(var value) { use(value) }
    case .Err(const e) where e.fatal { abort() }
    default { retry() }
}
match (Foo { a: 1 }) {        // scrutinee struct-lit needs parens
    case 1 { x() }
}

// NEGATIVE: missing block on case
match x {
    case 1 one()
}
// NEGATIVE: bare expr instead of case/default
match x {
    foo()
}
// NEGATIVE: missing scrutinee block
match x

// ── labeled loops ───────────────────────────────────────────────────────────
outer: while x { inner: while y { break outer } }
loop_a: for var i in items { continue loop_a }
counted: for var i = 0; i < n; i += 1 { foo() }
labeled_loop: loop { done() }

// NEGATIVE: label on non-loop
mylabel: foo()
// NEGATIVE: label on return
ret: return 5

// ── try / catch / finally ────────────────────────────────────────────────────
try { risky() } catch { recover() }
try { risky() } catch e { handle(e) }
try { risky() } catch e: IoError { handleIo(e) }
try { risky() }
    catch e: IoError { io(e) }
    catch e: NetError { net(e) }
    catch { fallback() }
finally { cleanup() }
try { a() } catch e: Error { b() } finally { c() }

// NEGATIVE: try without catch
try { risky() }
// NEGATIVE: catch missing block
try { risky() } catch e: IoError
// NEGATIVE: catch filter missing type
try { x() } catch e: { y() }
// NEGATIVE: finally missing block
finally

// ── unsafe block vs unsafe expr ───────────────────────────────────────────────
unsafe { deref(p) }
unsafe { *raw = 5 }
unsafe foo()             // unsafe EXPR (no brace) -> expr-stmt

// NEGATIVE: nothing after unsafe block open... handled by block recovery
unsafe {

// ── context binding (real: bindings parse) ────────────────────────────────────
file as var f { use(f) }
getResource() as var r { work(r) }
std::Io::File("foo.k", "w") as (var file, const disc) { write(file) }
acquire() as (var a, var b) { combine(a, b) }
lock(mutex) as var guard { critical() }

// NEGATIVE: binding spec but no block (hard error)
file as var f
// NEGATIVE: `as` then nothing
foo as
// NEGATIVE: empty binding list
res as var () { foo() }

// ── destructuring decl (real: bindings parse, value is expr) ──────────────────
var (a, b) = pair
const (x, y, z) = triple
var (a, const b) = pair
var (first, _, third) = triple
var {name, age} = person
const {r, g, b} = color
var (*p, q) = ptrPair

// NEGATIVE: missing `=`
var (a, b) pair
// NEGATIVE: missing value
var (a, b) =
// NEGATIVE: empty pattern
var () = thing

// ── label! / jump! intrinsics ─────────────────────────────────────────────────
//  NOTE: verify against your PP lowering -- these depend on how label!/jump!
//  tokenize. If PP rewrites them, adjust expectations.
label!(retry)
jump!(retry)

// NEGATIVE: missing paren
label!retry
// NEGATIVE: missing name
jump!()

// ── inline foreign blocks ─────────────────────────────────────────────────────
inline "c++" { ::std::printf("hi"); }
inline "c" { puts("hi"); }
inline "asm" { nop }

// NEGATIVE: missing language string
inline { foo() }
// NEGATIVE: unknown language (defaults to cpp + diag)
inline "rust" { foo() }

// ── eval block (decl-only, bodies are <decl> placeholder) ─────────────────────
eval { var x = 5 }
eval { const TABLE = compute() }

// NEGATIVE: missing brace
eval var x = 5

// ── nested / compound structure ───────────────────────────────────────────────
{
    var (a, b) = pair
    if a > b {
        for var i in 0..a { foo(i) }
    } else {
        while b > 0 { b -= 1 }
    }
    return a + b
}

// deeply nested blocks
{
    {
        {
            foo()
        }
    }
}

// mixed control flow with labels and context binding
outer: for var item in collection {
    item as var resource {
        if resource.ready {
            try { resource.use() } catch e { continue outer }
        }
    }
}