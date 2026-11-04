#pragma once
// Corpus for main.k: a move-only type only main.k's header set includes.
namespace eh {
struct Err {
  Err() = default;
  Err(Err &&) = default;
  Err(const Err &) = delete;
  int code = 0;
};
inline int consume(Err e) { return e.code; }
}
