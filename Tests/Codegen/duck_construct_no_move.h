#pragma once
// Neither copyable nor movable: a construction that is copied or moved
// anywhere on its way into a local does not compile.
struct NoMoveGuard {
    int* p;
    explicit NoMoveGuard(int* q) noexcept : p(q) { *p += 10; }
    NoMoveGuard(const NoMoveGuard&) = delete;
    NoMoveGuard(NoMoveGuard&&) = delete;
    ~NoMoveGuard() { *p += 1; }
};
