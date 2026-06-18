fn <T> sum(self, items: [T]) -> T {
    var total: T = 0 as T
    for var i in items {
        total += i
    }
    return total
}

// specialization:
fn <> sum<i32>(self, items: [i32]) -> i32 {
    var total: i32 = 0
    for var i in items {
        total += i
    }
    return total
}

