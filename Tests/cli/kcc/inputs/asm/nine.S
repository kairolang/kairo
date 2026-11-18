#ifndef VAL
#define VAL 9
#endif
    .text
    .globl asm_nine
    .type asm_nine,@function
asm_nine:
    movl $VAL, %eax
    ret
