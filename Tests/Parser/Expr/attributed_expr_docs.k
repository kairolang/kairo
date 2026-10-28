// Every `@create` example in the language docs, in expression position,
// parses (attributes.mdx, pointers.mdx, ownership.mdx, unsafe.mdx,
// tether*.mdx, allocators.mdx, classes.mdx, structures.mdx,
// variables.mdx, c-cpp-calling.mdx). Only the parse: what `@create` means
// is not implemented, and Sema says so (Sema/Check/attributed_expr_gate.k).

fn docs() {
    var *a = @create Mesh(vertices)
    var *b = @create Texture(pixels)
    var *cfg = @create Config(8080)
    var *cfg2 = @create EngineConfig(defaults())
    var *data = @create Buffer(1024)
    var *data2 = @create i32(100)
    var *expanded = @create AST::Block()
    var *foo = @create SomeClass()
    var *heap = @create Point{ x: 1.0, y: 2.0 }
    var *ptr = @create Config(data)
    var *ptr2 = @create Foo(42)
    var *x = @create i32(42)
    var *y = @create i32()
    var a2: *i32 = @create i32(120)
    var a3: *i32 = @create i32(n)
    var x2: unsafe *i32 = @create i32(41)
    var ptr3: std::Unique<Config> = @create Config(8080)
    var shared: std::Shared<Config> = @create Config(8080)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
