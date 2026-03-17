bold = "\033[1m"
r = "\033[31m"
rest = "\033[0m"
c = "\033[36m"
g = "\033[32m"
w = "\033[97m"
y = "\033[33m"
lg = "\033[92m"
st = "\033[9m"
ul = "\033[4m"

print(f"\n\n{r}error {rest}[{r}T41E{rest}]{rest}: function 'foo' has a 'void' return type but returns 'i32'{rest}")
print(f"    1 | fn {r}foo{rest}() {g}{ul}-> i32{rest} {{")
print(f"      |    {r}^^^   {g}++++++{rest}")
print(f"    2 |     return 1;{rest}")
print(f"    3 |  }}{rest}")
print(f"      > {g}fix:{rest} change the return type to 'i32'{rest}")
print(f"      > {c}note {rest}[{c}T21N{rest}]{rest}: the return is here:{rest}")
print(f"           1 | fn foo() -> i32 {{{rest}")
print(f"           2 |     {c}return{rest} {r}{st}1{rest};")
print(f"             |     {c}^^^^^^{rest} {r}-{rest}")
print(f"           3 | }}{rest}")
print(f"             > {g}alternative:{rest} remove the expression in the return statement{rest}\n\n")

print(f"\n\n{r}error {rest}[{r}T41E{rest}]{rest}: function 'foo' has a 'void' return type but returns 'i32'{rest}")
print(f"    1 | fn {r}foo{rest}() {g}{ul}-> i32{rest} {{")
print(f"      |    {r}^^^   {g}++++++{rest}")
print(f"    2 |     return 1;{rest}")
print(f"    3 |  }}{rest}")
print(f"      > {g}fix:{rest} change the return type to 'i32' or remove the expression after return{rest}\n\n")