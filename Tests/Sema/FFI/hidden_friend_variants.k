// A C++ hidden friend of a class template, with two Kairo instances that
// are ONE specialization to clang: `Box<usize>` and `Box<u64>` are both
// `Box<unsigned long>`. Each Kairo instance has its own members, typed by
// its own arguments (a "variant" fill); a hidden friend is written in the
// class but is an entity of the namespace, and was shared: the second
// instance's fill re-typed the first one's `operator==`, so the next file
// to compare two `Box<usize>` had no `==` (SC066E here; SC063E through
// libc++'s `__wrap_iter` when its comparison is a hidden friend, which
// broke `for x in vector<usize>` after any `vector<u64>`). Which file
// failed depended on check order. Inputs/hidden_friend: a.k compares
// usize, b.k u64, c.k usize again.
//
// Found by the live check's oracle (Scripts/incr_replay_check.py): a
// re-check runs a file later than a fresh run does.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -I %S/Inputs/hidden_friend %S/Inputs/hidden_friend/main.k --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not=error
