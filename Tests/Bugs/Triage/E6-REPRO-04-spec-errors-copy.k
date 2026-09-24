// build: kairo Z4-e6-spec-errors-copy.k --print-sema --type-check-only
// Copy of Tests/Sema/Scenarios/04_spec_errors.k for E6. The suite file claims
// EXPECT: error "explicit specialization of 'Late' after it was already
// instantiated" E6 says that never fires same-TU.
class <T> Pair { var a: T; var b: T }

class <> Pair<bool>;
class <> Pair<bool> { var packed: u8 }

class <> Pair<i32> { var x: i32 }
class <> Pair<i32> { var y: i32 }

class <T> Late { var v: T }
var early: Late<u8>
class <> Late<u8> { var w: u8 }

class <> Orphan<i32> { var z: i32 }
