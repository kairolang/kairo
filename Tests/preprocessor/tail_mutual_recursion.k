// Two macros that each END in an invocation of the other. Expanding `ping!`
// pops its exhausted frame before `pong!`'s body is walked, so the live frame
// stack the cycle check read never held both names: the pair expanded until
// the --cmax-macro-expansions budget, and every hop copied an origin chain one
// longer than the last, so reaching the default budget took minutes. The
// cycle is now caught off the origin chain captured at detection.

macro ping! ( x ) {
    pong! ( x )
}

macro pong! ( x ) {
    ping! ( x )
}

ping! ( 42 )

// --- lit wiring -----------------------------------------------------------
// REQUIRES: shell
// RUN: timeout 10 %kairo %s --syntax-only > %t.out 2>&1; test $? -eq 1
// RUN: %FileCheck %s --input-file=%t.out --implicit-check-not=PLEASE --implicit-check-not=Sanitizer --implicit-check-not=budget
// CHECK: tail_mutual_recursion.k:{{[0-9]+}}:{{[0-9]+}}: error [R008E]: cyclic expansion of macro 'ping!'
// CHECK: note{{.*}}recursion occurs here, in the macro body
