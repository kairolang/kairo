x = Foo { a: 1, b: Inner { c: 2 } }
Foo<i32>{ a: 1, b: Inner<i32>{ c: 2 } }
if (Foo{x:12}) { 210 } else { 420 } // parser checks for extance of else (must be present)
if call() { 210 } else { 420 }
if call() == 10 { 210 } else if call() == 20 { 420 } else { 630 }
try { call() } catch { 210 }
try { call() } catch var e { 210 }
try { call() } catch var e: Error { 210 } catch { 420 }
// default path is is not checked (like no error, since sema verifs exhaustivness) by parser if a typed catch is present
// defualt has 2 forms, catch { ... } and catch var e { ... } (untyped)
// typed catch has 1 form, catch var e: Error { ... } (typed)