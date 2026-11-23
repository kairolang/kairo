// The x86-64 level a feature list reaches (Native/HostCPU.k), through its
// own Test(): each level from a fixed list, a list one feature short of the
// next level, and a higher level's features without the level below them.
// The host CPU default picks the level this way from the host's features.

// --- lit wiring -----------------------------------------------------------
// RUN: %kunit HostCPU | %FileCheck %s
// CHECK-NOT: {{^}}FAIL
// CHECK-NOT: x86_64_level
// CHECK: ok HostCPU
