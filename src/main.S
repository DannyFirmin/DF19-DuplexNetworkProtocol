.syntax unified
.global main, EXTI0_IRQHandler, EXTI3_IRQHandler, timer_handler
.include "libcomp2300/macros.S"

@ --- PIN CONNECTIONS ---
@ PE14 -> PD0
@ PE15 -> PB3

/* Note on/off line, Sender: PE14, Receiver: PD0
 * Pitch change line, Sender: PE15, Receiver: PB3 */
.type main, %function
main:
  @ Enable SYSCFG clock
  RCC_APB2ENR_set 0

  @ Turn GPIO ports B, D, E on
  GPIOx_clock_enable B
  GPIOx_clock_enable D
  GPIOx_clock_enable E

  GPIO_configure_output_pin E, 14 @ Note on/off line, Sender
  GPIO_configure_output_pin E, 15 @ Pitch change line, Sender

  @ Configure on/off line Receiver
  GPIO_configure_input_pin_it D, 0
  EXTI_set_rising_edge_trigger 0
  EXTI_set_falling_edge_trigger 0
  NVIC_set ISER 6 @ Enable corresponding NVIC interrupt

  @ Configure pitch change line Receiver
  GPIO_configure_input_pin_it B, 3
  EXTI_set_rising_edge_trigger 3
  NVIC_set ISER 9

  @ Priority level: pitch changing interrupt(priority:1) > on/off interrupt(priority:2) > timer(priority:3)
  mov r0, #6
  mov r1, #2
  bl NVIC_IPR_set_priority

  mov r0, #9
  mov r1, #1
  bl NVIC_IPR_set_priority

  @ Init Sound playing
  bl init
  ldr r1, =p2300_sequence
  ldr r0, [r1]
  mov r1, 0x7FFF
  bl wave_change

  @ Use Timer7, seconds between interrupts = 0.25s
  mov r0, #20000
  mov r1, #1000
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

.type timer_handler, %function
@ Sender part. Called each 0.25s from TIM7_IRQHandler
timer_handler:
push {lr,r4-r10}
  ldr r1, =part1_song_pointer
  ldr r0, [r1] @ Load array poisiton into r0
  ldr r1, =part1_song
  lsl r2, r0, #2 @ Calculate the offset based on pointer value, r2 = r0 * 4, a faster way 
  ldr r9, [r1, r2] @ Load corresponding P2300 index into r9. Offset by pointer value

  cmp r9, #-1
  bne not_rest
  @ Condition met, turn off on/off line
  GPIOx_ODR_clear E, 14
  bl sync
  b handler_ending
  not_rest:
  @ compare new P2300 index (r9) to previous playing index (r2), if not equal, calculate how many time I need to increase in order to reach it
  ldr r1, =previous_P2300_index
  ldr r2, [r1]
  @ if r9 == r2
  cmp r9, r2
  beq handler_play
  bls less
  @ if r9 > r2
  sub r0, r9, r2
  bl fire_pulse
  b handler_play
  less:
  @ if r9 < r2, increase number = 8 - previous playing index(r2) + new P2300 index (r9) 
  mov r0, #8
  sub r0, r2
  add r0, r9
  bl fire_pulse

  handler_play:
  GPIOx_ODR_set E, 14 @ Turn on on/off line
  bl sync
  ldr r0, =previous_P2300_index
  str r9, [r0]
  handler_ending:
  bl increase_pointer
  pop {lr,r4-r10}
  bx lr
.size timer_handler, .-timer_handler

increase_pointer:
  push {lr}
  @ Load array poisiton into r0
  ldr r1, =part1_song_pointer
  ldr r0, [r1]

  @ pointer++, if more than 37, minus it back to 0
  add r0, #1
  cmp r0, #37
  IT hi
  blhi pointer_outof_bound
  @ Store it back
  str r0, [r1]
  pop {lr}
  bx lr

.type fire_pulse, %function
@ --parameters--
@ r0: fire for how many times, r0 should be a positive number
fire_pulse:
  push {lr, r4}
  mov r4, r0
  fire_loop:
  sub r4, #1
  @ Send signal by create a pulse
  GPIOx_ODR_set E, 15
  GPIOx_ODR_clear E, 15
  mov r0, #12
  bl custom_sync
  cmp r4, #0
  bne fire_loop
  pop {lr, r4}
  bx lr
.size fire_pulse, .-fire_pulse

.type custom_sync, %function
@ To make sure a interrupt is fully executed
@ --parameters--
@ r0: sync how many time
custom_sync:
  push {lr}
  sync_start:
  subs r0, #1
  bls sync_end
  push {r0}
  bl sync
  pop {r0}
  b sync_start
  sync_end:
  pop {lr}
  bx lr
.size custom_sync, .-custom_sync

@ Receiver for "on/off" line
.type EXTI0_IRQHandler, %function
EXTI0_IRQHandler:
  push {lr}
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
  pop {lr}
  bx lr
.size EXTI0_IRQHandler, .-EXTI0_IRQHandler


@ Receiver for Line "pitch change"
.type EXTI3_IRQHandler, %function
EXTI3_IRQHandler:
  push {lr}

  @ Load array poisiton into r0
  ldr r1, =p2300_sequence_pointer
  ldr r0, [r1]
  add r0, #1
  cmp r0, #7
  IT hi
  blhi pointer_outof_bound
  str r0, [r1]

  @ Load frequency into r0
  ldr r1, =p2300_sequence
  lsl r2, r0, #2 @ Calculate the offset based on pointer value, r2 = r3 * 4, a faster way 
  ldr r0, [r1, r2]
  mov r1, 0x7FFF
  bl wave_change

  EXTI_PR_clear_pending 3
  pop {lr}
  bx lr
.size EXTI3_IRQHandler, .-EXTI3_IRQHandler

.type pointer_outof_bound, %function
@ If pointer is more than the array size, make it back to 0
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

part1_song:
@ P2300 index of the song
.word 0, -1, 2, -1, 1, -1, 3, -1, 2, -1, 4, -1, 3, -1, 5, -1, 4, -1, 6, -1, 5, -1, 7, -1, 6, -1, 5, -1, 4, -1, 3, -1, 2, -1, 1, -1, 0, -1
part1_song_pointer:
.word 0
previous_P2300_index:
.word 0

@ Playing Flag. If 0 means don't play. If 1 means play
playflag:
.word 0
@ P2300 defined pitch(Hz) scaled by 100
p2300_sequence:
.word 22000, 24694, 26163, 29366, 32963, 36999, 39200, 44000
p2300_sequence_pointer:
.word 0
