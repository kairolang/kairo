/**
 * Memory wise since this is the first thing we need to figure out before anything else
 *
 */

fn __builtin_alloc(size: usize) -> *void
fn __builtin_alloc_zero(size: usize) -> *void
fn __builtin_alloc_align(size: usize, alignment: usize) -> *void
fn __builtin_free(ptr: *void)
fn __builtin_realloc(ptr: *void, new_size: usize) -> *void
fn <T, ...U> __builtin_construct_at(ptr: *void, ...args: U)
fn <T> __builtin_destruct_at(ptr: *T)
fn <T> __builtin_size_of() -> usize
fn <T> __builtin_align_of() -> usize
fn __builtin_copy(dst: *void, src: *void, size: usize)
fn __builtin_move_mem(dst: *void, src: *void, size: usize)
fn __builtin_set_mem(ptr: *void, value: byte, size: usize)
fn __builtin_has_scoped_alloc() -> bool
fn <T> __builtin_is_trivial_destruct() -> bool
fn <T> __builtin_is_trivial_construct() -> bool
fn <T> __builtin_is_trivial_copy() -> bool
fn <N: usize> __builtin_crash(msg: const [char; N], exit_code: i32) -> !
fn <N: usize> __builtin_signal(msg: const [char; N], signal: SIGNAL) -> !
fn __builtin_max_align() -> usize

/// full family of compiler inbuilt attributes
/// @create    - allocates and initializes
/// @destroy   - cleans up and deallocates
/// @free      - frees memory
/// @alloc     - allocates memory
/// @realloc   - reallocates memory
/// @construct - constructs an object at a given location
/// @destruct  - destroys an object at a given location
///
/// Macros:
/// memcpy!
/// memmove!
/// memset!

macro memcpy!(dst, src, size)   { __builtin_copy(dst, src, size);      }
macro memmove!(dst, src, size)  { __builtin_move_mem(dst, src, size);  }
macro memset!(ptr, value, size) { __builtin_set_mem(ptr, value, size); }

/// Usage:
/// ```kairo
/// @create T(args...)
/// @create i32(10)
/// ```
macro @create(node: *AST::CallExpression) {
    // this one needs to do something transformational
    // we will always have a call expression
    // we need to generate roughly:
    // @create i32(10) - Node wise is a CallExpression with a name: ChainExpr, and arguments: [LiteralExpr(10)]
    // it becomes:
    // __builtin_construct_at<name as Type>(__builtin_alloc(sizeof name as Type), args...)
    // Nodes to create:
    // 1. CallExpr(name: ChainExpr, arguments: [LiteralExpr(10)], generics: [name as Type])
    
    var node_name = AST::ToCode(node.name);
    var construct = AST::ParseCallExpr(f"__builtin_construct_at<{node_name}>(__builtin_alloc(sizeof {node_name}))");
    construct.arguments.append_all(node.arguments);
    AST::Transform(node, construct);
}

@create i32(10) // works now cleanly
@create [i32; 10] // doesn't work yet but should work soon