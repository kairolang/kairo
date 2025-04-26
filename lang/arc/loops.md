# loops
- break
- continue
- for
- while

// TODO: one liner loops 
    

---

## Table of Contents
- [loops](#loops)
  - [Table of Contents](#table-of-contents)
    - [Python style For Loop](#python-style-for-loop)
    - [C style For Loop](#c-style-for-loop)
    - [While Loop](#while-loop)
    - [Break](#break)
    - [Continue](#continue)
  - [Examples](#examples)

---

### Python style For Loop
```rs
for i in range(10) {
    print(i);
}
```

### C style For Loop
```rs
for let i = 0; i < 10; i++ {
    print(i);
}
```

### While Loop
```rs
let i = 0;
while i < 10 {
    print(i);
    i += 1;
}
```

### Break
```rs
while true {
    break;
}

let i = while true {
    return 5; // also breaks the loop and assigns 5 to i
}
```

### Continue
```rs
for i in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] {
    if i == 5 {
        continue;
    }
    print(i); // 1, 2, 3, 4, 6, 7, 8, 9, 10 // skips 5
}
```

### One Line loops
```py
for i in 0..10: print(i);
```



---

## Examples
```rs
#[no_entry]

fn shuffle<T>(arr: list<T>) -> list<T> {
    const let len = arr.len();
    
    let result:  list<T>   = [];
    let indices: list<int> = [];
    
    for i in range(len) {
        indices.append(i);
    }

    while indices.len() > 0 {
        let index: int = random(0, indices.len());
        result.append(arr[indices[index]]);
        indices.remove(index);
    }

    return result;
}

let arr: list<int> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
let shuffled: list<int> = shuffle(arr);

print(shuffled); // [5, 1, 3, 6, 2, 10, 4, 9, 7, 8] // random order
```
