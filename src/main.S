.syntax unified
.global main
.include "libcomp2300/macros.S"
@ please fill in the pin connections below
@ eg. PA0 -> PB1
@ --- PIN CONNECTIONS ---
@ 
@ 

.type main, %function
main:
  nop
  b main
.size main, .-main




.data
.align 2
@ \/ memory entries go here \/