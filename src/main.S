.syntax unified
.global main, EXTI0_IRQHandler, EXTI1_IRQHandler, EXTI3_IRQHandler, EXTI15_10_IRQHandler, pointer_outof_bound, checksum_xor
.include "libcomp2300/macros.S"
@ DF19 protocol invented by Danny at ANU
@ --- PIN CONNECTIONS ---
@ SENDER <-> RECEIVER
 @ PE14   ->  PD0  (Control line)
 @ PE15   ->  PB3  (Data line)
 @ PE13   ->  PH1  (Clock line)
 @ PE11   <-  PA2  (For receiver to talk to sender, currently used to tell sender the data is incorrect, please resend)


.type main, %function
main:
  @ Enable SYSCFG clock
  RCC_APB2ENR_set 0

  @ Turn GPIO ports A, B, D, E, H on
  GPIOx_clock_enable A
  GPIOx_clock_enable B
  GPIOx_clock_enable D
  GPIOx_clock_enable E
  GPIOx_clock_enable H

  GPIO_configure_output_pin E, 14 @ Control line, Sender
  GPIO_configure_output_pin E, 15 @ Data line, Sender
  GPIO_configure_output_pin E, 13 @ Clock line, Sender
  GPIO_configure_output_pin A, 2  @ For data resend request

  @ Configure Control line Receiver
  GPIOx_ODR_set E, 14 @ Start from high 
  GPIO_configure_input_pin_it D, 0
  EXTI_set_rising_edge_trigger 0
  EXTI_set_falling_edge_trigger 0
  NVIC_set ISER 6 @ Enable corresponding NVIC interrupt

  @ Configure Data line Receiver
  GPIO_configure_input_pin B, 3

  @ Configure Clock line Receiver
  GPIO_configure_input_pin_it H, 1
  EXTI_set_rising_edge_trigger 1
  NVIC_set ISER 7

  @ Data resend request line
  GPIO_configure_input_pin_it E, 11
  EXTI_set_rising_edge_trigger 11
  NVIC_set ISER 40

  @ Priority level: data Error interrupt(priority:0) > clock interrupt(priority:1) > timer(priority:2) > control line(priority:3)
  mov r0, #6
  mov r1, #3
  bl NVIC_IPR_set_priority

  mov r0, #40
  mov r1, #0
  bl NVIC_IPR_set_priority

  mov r0, #7
  mov r1, #1
  bl NVIC_IPR_set_priority

  bl red_led_init
  bl green_led_init
  bl red_led_on
  
  
  @ Init Sound playing
  bl init

  @ Use Timer7, seconds between interrupts = 0.0125s. 10 bytes per second
  @ mov r0, #5000
  @ mov r1, #200
  /* Use the code below if you want it to send data slower. 1 byte per second
  ** When testing error checking, use this code to make the transmission slower,
  ** and unplug some wires. Green and Red LEDs will flush three times when transmission error detected */

  mov r0, #10000
  mov r1, #8000
  bl tim7_init

.size main, .-main

@ waiting for a interrupt or playing the music
loop:
  mov r3, #0
  @ if control line is on, which means receiving data, don't play
  @ if control line is off, which means data transmit success, start play
  check_control:
  ldr r0, =controlflag
  ldr r1, [r0]
  cmp r1, #1
  beq check_control
  
  push {r3}
  bl red_led_off
  bl green_led_on
  bl clean_up
  pop {r3}

  ldr r0, =pitch_received
  lsl r2, r3, #2
  ldr r1, [r0, r2]
  mov r2, #1
  udiv r2, r1, r2 @ r2 is loop how many time, to fit in the previous function I made
  push {r3}
  bl play_note
  pop {r3}
  add r3, #1
  ldr r0, =datalength
  ldr r1, [r0]
  cmp r3, r1
  blt check_control
  mov r3, 0
  b check_control

@ Receiver for Control line
.type EXTI0_IRQHandler, %function
EXTI0_IRQHandler:
  stmdb sp!,{lr}
  @ Load the control flag, change to 1 if the wave is high, change to 0 if the wave is low
  GPIOx_IDR_read D, 0
  cmp r0, #1
  bne mute
  @ if it is high
  ldr r1, =controlflag
  mov r2, #1
  str r2, [r1]
  b exti0_end
  mute:
  @ if it is low
  ldr r1, =controlflag
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
  stmdb sp!,{lr, r4-r6}
  @ if checksum is not -1, means now it is the time to do checksum
  ldr r0, =receiver_checksum
  ldr r1, [r0]
  ldr r2, =#-1
  cmp r1, r2
  bne checksum_received
  reading:
  GPIOx_IDR_read B, 3 @ Read from data line
  ldr r1, =clock_counter
  ldr r2, [r1] @ Counter
  lsl r4, r2, #2 @ Calculate the offset based on pointer value, r4 = r2 * 4, a faster way 
  ldr r3, =databit_received
  str r0, [r3, r4] @ Store this bit to memory
  @ Increase clock counter
  add r2, 1
  cmp r2, #15
  @ if r2 > 15, means finished sending a 16 bit data
  IT hi
  blhi finished_hword
  ldr r1, =clock_counter
  str r2, [r1]
  b exti1_end
  checksum_received:
  ldr r1, =checksum_state 
  ldr r0, [r1]
  cmp r0, 0 @ if it is the first time doing checksum, we need to clear the clock cunter
  IT eq
  bleq clean_up
  ldr r1, =checksum_state 
  mov r0, 1
  str r0, [r1]  
  b reading
  exti1_end:
  EXTI_PR_clear_pending 1
  ldmia sp!, {lr, r4-r6}
  bx lr
.size EXTI1_IRQHandler, .-EXTI1_IRQHandler

@ Receiver for Line "pitch change"

.type finished_hword, %function
@ Finished sending 16 bit. Clean up. And assemble the data
@ It will calculate the checksum and store it
@ --parameters--
@ none
@ --returns--
@ r1: Assembled data - currently doesn't used
@ r2: 0, in order to reset the pointer
finished_hword:
  push {lr, r4-r6}
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
  
  @ if checksum_state is 1, do not store checksum as pitch
  ldr r1, =checksum_state 
  ldr r0, [r1]
  cmp r0, 1
  beq checksum_case

  ldr r1, =data_received_count
  ldr r2, [r1]
  @ if r2 == 0, means it is the fisrt data
  cmp r2, 0
  bne not_first
  ldr r1, =datalength
  str r5, [r1]
  b end_first
  not_first:
  sub r2, 1
  lsl r1, r2, #2
  ldr r0, =pitch_received

  str r5, [r0, r1]
  b end_first

  checksum_case:
  ldr r1, =checksum_state @ clear partiy state
  mov r0, 0
  str r0, [r1]  

  ldr r1, =receiver_checksum
  ldr r6, [r1]
  ldr r0, =#-1
  str r0, [r1]

  cmp r5, r6
  IT ne
  blne transmit_error
  b pass

  end_first:
  @ Received count ++
  ldr r1, =data_received_count
  ldr r2, [r1]
  add r2, #1
  str r2, [r1]
  @ Remember to clear count when read data received in other functions
 
  @ Calculate and store checksum
  mov r0, r5
  bl checksum_xor
  ldr r1, =receiver_checksum
  str r0, [r1]
  pass:
  mov r1, r5
  mov r2, 0
  pop {lr, r4-r6}
  bx lr
.size finished_hword, .-finished_hword

.type EXTI15_10_IRQHandler, %function
EXTI15_10_IRQHandler:
  stmdb sp!,{lr}
  GPIOx_IDR_read E, 11
  cmp r0, 1
  IT eq
  bleq reset_sender
  EXTI_PR_clear_pending 11
  ldmia sp!, {lr}
  bx lr
.size EXTI15_10_IRQHandler, .-EXTI15_10_IRQHandler


.type transmit_error, %function
@ Checksum test failed
transmit_error:
  stmdb sp!,{lr, r4}
  mov r4, #2
  error_blink:
  bl green_led_off
  bl red_led_off
  ldr r0, =#2000000
  bl custom_sync
  bl green_led_on
  bl red_led_on
  ldr r0, =#2000000
  bl custom_sync
  subs r4, 1
  bpl error_blink

  bl restore
  GPIOx_ODR_set A, 2
  bl sync
  GPIOx_ODR_clear A, 2
  @ RESET BOARD
  ldr r0, =0xE000ED0C
  mov r2, #16
  ldr r3, =0x05FA
  lsl r3, r2
  orr r3, 0b100
  str r3, [r0]
  bl sync
  
  ldmia sp!, {lr, r4}
  bx lr
.size transmit_error, .-transmit_error
.type clean_up, %function
@ Clean up and get ready for next transmit
clean_up:
  stmdb sp!,{lr}

  ldr r1, =clock_counter
  mov r0, 0
  str r0, [r1]

  ldmia sp!, {lr}
  bx lr
.size clean_up, .-clean_up

.type restore, %function
@ When error happens, restore everything
restore:
  stmdb sp!,{lr}
  bl red_led_off
  bl green_led_off

  ldr r1, =controlflag
  mov r0, 1
  str r0, [r1]

  bl clean_up

  ldr r1, =clock_counter
  ldr r0, [r1]
  sub r0, 1
  str r0, [r1]

  ldr r1, =checksum_state
  mov r0, 0
  str r0, [r1]

  ldr r1, =datalength
  ldr r2, =data_received_count
  mov r0, 0
  str r0, [r1]
  str r0, [r2]

  ldr r1, =receiver_checksum
  ldr r6, [r1]
  ldr r0, =#-1
  str r0, [r1]
  mov r5, 0
  mov r6, 0
  EXTI_PR_clear_pending 0
  EXTI_PR_clear_pending 1

  ldmia sp!, {lr}
  bx lr
.size restore, .-restore

.type checksum_xor, %function
@ Calculate the checksum of a data
@ --parameters--
@ r0 : the 16 bit data would like to calculate its checksum
@ --returns--
@ r0 : result of the checksum
checksum_xor:
  stmdb sp!,{lr, r4-r6}
  mov r4, r0 @ store the data
  mov r5, #15 @ local counter
  mov r6, 0 @ store previous xor result
  checksum_xor_loop:
  mov r0, r4
  lsr r0, r5 @ shift right by the value in counter
  eor r6, r0, r6 @ Do XOR
  sub r5, 1
  cmp r5, 0
  bge checksum_xor_loop
  mov r0, r6
  ldmia sp!, {lr, r4-r6}
  bx lr
.size checksum_xor, .-checksum_xor

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
@ Control Flag. If 0 means control line is low. 1 means control line is high, it is high when start
controlflag:
  .word 1

@ Store the 16 bit data
databit_received:
  .word -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1

clock_counter:
  .word 0

datalength:
  .word 0

receiver_checksum: @ The checksum that reciver calculated based on the previous sent data
  .word -1

checksum_state: @ 1 means it's in checksum sending/receiving state, so no need to calculate checksum for a checksum
  .word 0

data_received_count: @ not include first data, which represent length
  .word 0

@ Reserve memory (Heap)
@ Reference the answers under my post in COMP2300 piazza https://piazza.com/class/js9iyij0aiy637?cid=541
pitch_received:
// Heap is the area in memory where you can create arbitrarily large data structures (until you run out of space).
  .word 0
.skip 12000 // Allocate 12kB of memory starting at the heap label