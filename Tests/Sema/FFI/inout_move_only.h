#pragma once
struct MV { int v = 4; MV() {} MV(const MV &) = delete; MV(MV &&) noexcept {} MV &operator=(MV &&) noexcept { return *this; } };
