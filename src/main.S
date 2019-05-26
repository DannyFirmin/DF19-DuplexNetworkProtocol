.syntax unified
.global main, EXTI0_IRQHandler, EXTI1_IRQHandler, EXTI3_IRQHandler, pointer_outof_bound
.include "libcomp2300/macros.S"

@ --- PIN CONNECTIONS ---
@ PE14 -> PD0
@ PE15 -> PB3
@ PE13 -> PH1

/* Control line, Sender: PE14, Receiver: PD0
 * Data line, Sender: PE15, Receiver: PB3 
 * Clock line, Sender: PE13, Receiver: PH1 */
.type main, %function
main:
  @ Enable SYSCFG clock
  RCC_APB2ENR_set 0

  @ Turn GPIO ports B, D, E, H on
  GPIOx_clock_enable B
  GPIOx_clock_enable D
  GPIOx_clock_enable E
  GPIOx_clock_enable H

  GPIO_configure_output_pin E, 14 @ Control line, Sender
  GPIO_configure_output_pin E, 15 @ Data line, Sender
  GPIO_configure_output_pin E, 13 @ Clock line, Sender

  @ Configure Control line Receiver
  GPIO_configure_input_pin_it D, 0
  @ EXTI_set_rising_edge_trigger 0
  @ EXTI_set_falling_edge_trigger 0
  NVIC_set ISER 6 @ Enable corresponding NVIC interrupt

  @ Configure Data line Receiver
  GPIO_configure_input_pin_it B, 3
  @ EXTI_set_rising_edge_trigger 3
  NVIC_set ISER 9

  @ Configure Clock line Receiver
  GPIO_configure_input_pin_it H, 1
  EXTI_set_rising_edge_trigger 1
  NVIC_set ISER 7

  @ Priority level: pitch changing interrupt(priority:1) > on/off interrupt(priority:2) > timer(priority:3)
  mov r0, #6
  mov r1, #3
  bl NVIC_IPR_set_priority

  mov r0, #9
  mov r1, #2
  bl NVIC_IPR_set_priority

  mov r0, #7
  mov r1, #1
  bl NVIC_IPR_set_priority

 @ Init Sound playing
  bl init
  @ ldr r1, =p2300_sequence
  ldr r0, [r1]
  mov r1, 0x7FFF
  bl wave_change

  @ Use Timer7, seconds between interrupts = 0.0125s
  @ mov r0, #5000
  @ mov r1, #200
  mov r0, #10000
  mov r1, #8000
  bl tim7_init


.size main, .-main

@ waiting for a interrupt or playing the music
loop:
  ldr r0, =playflag
  ldr r1, [r0]
  cmp r1, #1
  bne loop
  bl wave_play_next_sample
  b loop

@ Receiver for "on/off" line
.type EXTI0_IRQHandler, %function
EXTI0_IRQHandler:
  stmdb sp!,{lr}
  @ Load the play flag, change to 1 if the wave is high, change to 0 if the wave is low
  GPIOx_IDR_read D, 0
  cmp r0, #1
  bne mute
  @ if it is high
  ldr r1, =playflag
  mov r2, #1
  str r2, [r1]
  b exti0_end
  mute:
  @ if it is low
  ldr r1, =playflag
  mov r2, #0
  str r2, [r1]
  exti0_end:
  EXTI_PR_clear_pending 0
  ldmia sp!, {lr}
  bx lr
.size EXTI0_IRQHandler, .-EXTI0_IRQHandler

@ Receiver for Line "Clock"
.type EXTI1_IRQHandler, %function
EXTI1_IRQHandler:
  stmdb sp!,{lr}

  GPIOx_IDR_read B, 3 @ Read from data line
  ldr r1, =clock_counter
  ldr r2, [r1] @ Counter
  lsl r4, r2, #2 @ Calculate the offset based on pointer value, r4 = r2 * 4, a faster way 
  ldr r3, =databit_received
  str r0, [r3, r4] @ Store this bit to stack
  @ Increase clock counter
  add r2, 1
  cmp r2, #15
  @ if r2 > 15
  IT hi
  blhi finished_hword
  ldr r1, =clock_counter
  str r2, [r1]
  EXTI_PR_clear_pending 1
  ldmia sp!, {lr}
  bx lr
.size EXTI1_IRQHandler, .-EXTI1_IRQHandler

@ Receiver for Line "pitch change"

.type finished_hword, %function
@ Finished sending 16 bit. Clean up. And assemble the data
@ --returns--
@ r2: 0, in order to reset the pointer
finished_hword:
  push {lr, r4, r5}
  mov r4, #0 @ local counter
  mov r5, #0 @ Assembled data
  assemble_data:
  ldr r1, =databit_received
  lsl r3, r4, #2 @ Calculate the offset based on pointer value, r3 = r4 * 4, a faster way 
  ldr r2, [r1, r3]
  mov r3, #15
  sub r3, r4
  lsl r2, r3 @ shift left by the value in counter
  orr r5, r2
  add r4, 1 @ counter ++
  cmp r4, #16
  bls assemble_data
  
  ldr r0, =data_received
  str r5, [r0]

  mov r2, 0
  pop {lr, r4, r5}
  bx lr
.size finished_hword, .-finished_hword

.type EXTI3_IRQHandler, %function
EXTI3_IRQHandler:
  stmdb sp!,{lr}



  EXTI_PR_clear_pending 3
  ldmia sp!, {lr}
  bx lr
.size EXTI3_IRQHandler, .-EXTI3_IRQHandler

.type pointer_outof_bound, %function
@ If pointer is more than the array size, make it back to 0
@ Normally used under branch condition
@ --parameters--
@ r0: out of bound pointer index
@ --returns--
@ r0: restore index to 0
pointer_outof_bound:
  push {lr}
  mov r0, #0
  pop {lr}
  bx lr
.size pointer_outof_bound, .-pointer_outof_bound


.data
.align 2
@ Receiver's Memory
@ Playing Flag. If 0 means don't play. If 1 means play
playflag:
.word 0

@ Store the 16 bit data
databit_received:
.word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
databit_received_pointer:
.word 0

data_received:
.word 0

clock_counter:
.word 0
