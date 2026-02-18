"""
print:

error: expected a reference to an 'int' but got a copy instead
    -->  at tests/main.kro:1:4
   1 | let result? = divide(x, y);
     :               ~~~~~~~^~~~~
     |
  fix: change the call to `divide(&x, y);`

    note: the function definition is:
       -->  at tests/main.kro:4:4
      4 | fn divide(parm1: &int, const parm2: i32) -> Exception? {
      5 |     if parm2 == 0 {
      6 |         return DivideByZero;

error: aborting due to previous error

with color
"""

bold = "\033[1m"
red = "\033[31m"
reset = "\033[0m"
cyan = "\033[36m"
green = "\033[32m"
white = "\033[97m"
yellow = "\033[33m"
light_green = "\033[92m"

print("this is how errors in kairo should look after the completion of the self-hosted compiler\n\n\n\n\n")
print(bold + red + "error [T42E]" + reset + white + ": expected an '*i32' (pointer) but got an 'i32' (copy) instead" + reset)
print("    --> " + white + " file " + light_green + "tests/main.kro" + white + ":" + yellow + "1" + white + ":" + yellow + "4" + reset)
print("   1 | " + white + "let result: i32? = divide(" + bold + red + "val1" + white + ", val2);" + reset)
print("     :                    " + reset + "~~~~~~~" + red + "^^^^" +  reset + "~~~~~~~" + reset)
print("   2 | if result? {" + reset)
print("   3 |     print(f\"value: {result}\");" + reset)
print("     |")
print(bold + green + "  fix" + reset + white + ": change the call to '" + bold + green + "divide(&val1, val2)" + reset + white + "' to pass a pointer instead of a value." + reset)
print()
print("    " + bold + "\033[36m" + "note" + reset + white + ": the function definition is:" + reset)
print("       --> " + white + " file " + light_green + "tests/main.kro" + white + ":" + yellow + "4" + white + ":" + yellow + "4" + reset)
print("      4 | " + white + "fn divide(parm1: *i32, const parm2: i32) -> i32? {" + reset)
print("      5 |     if parm2 == 0:" + reset)
print("      6 |         panic DivideByZero(\"Attempted to perform div by 0\");" + reset)
print()
print(bold + red + "error" + reset + white + ": aborting due to previous error" + reset)
print("\n\n\n\n\n")
