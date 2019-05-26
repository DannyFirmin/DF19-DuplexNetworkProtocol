.syntax unified

@ ------------------------ TIM7 ------------------------
@ Timer 7 features a 16-bit prescaler and a 16-bit counter.
@ The prescaler divides the main clock (which runs at 80MHz according to definition in HAL),
@ and the counter counts up according to the divided clock.
@ When the counter counts up to the reload value,
@ an update event is triggered and an interrupt is fired.

@ --------------------- Module Interface --------------------
.global tim7_init, TIM7_IRQHandler

@ --------------------- Implementation --------------------
.include "libcomp2300/macros.S"
.set CK_PSC, 80000000

.type tim7_init, %function
@ tim7_init takes two parameters, clock divisor and count (in each case, only the lower 16-bits will be used)
@
@ the clock divisor determines how many CPU cycles per TIM7 tick
@ the count determines how many TIM7 ticks between the TIM7 interrupts firing
@
@ Remember that in the assignment template, the main clock is at 80MHz
@ so, for example, clock divisor = 10000 and count = 8000 will give a 1Hz interrupt
@ 
@ In short, (seconds between interrupts) = (clock divisor * count) / 80000000
@
@ --parameters--
@ r0: clock divisor (prescaler + 1)
@ r1: count
tim7_init:
  push {r4-r5, lr}
  mov r4, r0
  mov r5, r1

  @ enable peripheral clock
  @ RCC_APB1ENR_set 5
  ldr r0, =ADR_RCC
  ldr r1, =OFS_RCC_APB1ENR
  ldr r2, =5
  bl set_bit

  @ Set prescaler
  @ the counter clock frequency f(CK_CNT) = f(CK_PSC) / (prescaler + 1)
  @ since clock divisor = prescaler + 1,
  @ subtract 1 here to get the prescaler
  @ See Section 29.4.7
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_PSC
  sub r4, 1
  strh r4, [r0, r1]

  @ set counter reload value (Section 29.4.8)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_ARR
  strh r5, [r0, r1]

  @ TIM7_EGR (Section 29.4.5)
  ldr r0, =ADR_TIM7
  ldr r1, =0x14
  ldr r2, [r0, r1]
  orr r2, 0b1
  str r2, [r0, r1]

  @ clear interrupt (Section 29.4.4)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_SR
  mov r2, 0
  bl clear_bit

  @ enable timer 7  (Section 29.4.1s)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_CR1
  mov r2, 0
  bl set_bit

  @ enable TIM7 DMA/interrupt (Section 29.4.3)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_DIER
  mov r2, 0
  bl set_bit

  @ enable TIM7 interrupt in NVIC
  NVIC_set ISER 55  @ TIM7 is at position 55

  @ set debug freeze (Section 44.16.4)
  ldr r0, =ADR_DBGMCU_APB1FZR1
  mov r1, 0
  mov r2, 5
  bl set_bit

  @ NOTE: you MAY want to configure the priority of TIM7.
  @ put your code here if that's the case

  @ ====MY CODE STARTS====
  mov r0, #55 @ TIM7 is at position 55 as mentioned above
  mov r1, #3
  bl NVIC_IPR_set_priority
  @ =====MY CODE ENDS=====
  bl sync
  pop {r4-r5, lr}
  bx lr
.size tim7_init, .-tim7_init

@ Sender part
.type TIM7_IRQHandler, %function
@ --parameters--
@ none
TIM7_IRQHandler:
  @ Your interrupt handler code goes here
  push {lr,r4-r10}


  ldr r1, =array_pointer
  ldr r0, [r1] @ Load array poisiton into r0
  @ Turn on control line
  cmp r0, #0
  bne not_first
  @ if it's the first
  GPIOx_ODR_set E, 14
  bl sync
  not_first:
  ldr r1, =song_pitch_tosend
  ldr r0, [r1]
  bl send_bit


  @ ldr r1, =part2_song_pointer
  @ ldr r0, [r1] @ Load array poisiton into r0
  @ ldr r1, =part2_song
  @ lsl r2, r0, #2 @ Calculate the offset based on pointer value, r2 = r0 * 4, a faster way 
  @ ldr r9, [r1, r2] @ Load corresponding P2300 index into r9. Offset by pointer value

  @ ldr r1, =part2_interval
  @ ldr r0, [r1] @ Check if it is the interval, if 1 means it's interval, don't play and toggle the interval flag.
  @ cmp r0, #1
  @ bne not_interval
  @ @ Case r0 = 1, is interval
  @ mov r0, #0
  @ str r0, [r1]
  @ GPIOx_ODR_clear E, 14
  @ bl sync
  @ b handler_ending
  @ not_interval:
  @ @ compare new P2300 index (r9) to previous playing index (r2), if not equal, calculate how many time I need to increase in order to reach it
  @ ldr r1, =previous_P2300_index
  @ ldr r2, [r1]
  @ @ if r9 == r2
  @ cmp r9, r2
  @ beq handler_play
  @ bls less
  @ @ if r9 > r2
  @ sub r0, r9, r2
  @ bl fire_pulse
  @ b handler_play
  @ less:
  @ @ if r9 < r2, increase number = 8 - previous playing index(r2) + new P2300 index (r9) 
  @ mov r0, #8
  @ sub r0, r2
  @ add r0, r9
  @ bl fire_pulse

  @ handler_play:
  @ GPIOx_ODR_set E, 14 @ Turn on on/off line
  @ bl sync
  @ ldr r0, =previous_P2300_index
  @ str r9, [r0]
  @ @ The next sound should be a rest.
  @ ldr r1, =part2_interval
  @ mov r0, #1
  @ str r0, [r1] 
  @ bl increase_pointer
  @ handler_ending:
  @ Clear interrupt (Section 29.4.4)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_SR
  mov r2, 0
  bl clear_bit
  bl sync
  pop {lr,r4-r10}
  bx lr
.size TIM7_IRQHandler, .-TIM7_IRQHandler

@ increase_pointer:
@   push {lr}
@   @ Load array poisiton into r0
@   ldr r1, =part2_song_pointer
@   ldr r0, [r1]

@   @ pointer++, if more than 18 (part-2 song array size), minus it back to 0
@   add r0, #1
@   cmp r0, #18
@   IT hi
@   blhi pointer_outof_bound
@   @ Store it back
@   str r0, [r1]
@   pop {lr}
@   bx lr

.type send_bit, %function
@ --parameters--
@ r0: the half word to send
send_bit:
  push {lr, r4}
  mov r4, #15 @ left most bit first, position 15
  keep_sending:
  lsr r0, r4 @ shift right by the value in counter
  ands r0, 1 @ get the bit in r0
  @ if r0 == 1, set data line to 1
  cmp r0, #1
  bne clear_data @ if r0 != 1, clear data line to 0
  GPIOx_ODR_set E, 15
  b finished_set
  clear_data:
  GPIOx_ODR_clear E, 15
  finished_set:
  @ Fire it! Trigger clock intrerupt
  GPIOx_ODR_set E, 13
  bl sync
  GPIOx_ODR_clear E, 13
  bl sync

  sub r4, 1
  @ if r4 >= 0, continue
  cmp r4, 0
  @ bge keep_sending
  pop {lr, r4}
  bx lr
.size send_bit, .-send_bit

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

.type tim7_stop, %function
tim7_stop:
  push {lr}
  @ disable peripheral clock
  @ RCC_APB1ENR_set 5
  ldr r0, =ADR_RCC
  ldr r1, =OFS_RCC_APB1ENR
  ldr r2, =5
  bl clear_bit

  @ disable timer 7  (Section 29.4.1s)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_CR1
  mov r2, 0
  bl clear_bit

  @ disable TIM7 DMA/interrupt (Section 29.4.3)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_DIER
  mov r2, 0
  bl clear_bit
  pop {lr}
  bx lr
.size tim7_stop, .-tim7_stop
@ Sender's Memory
.data

song_pitch_tosend:
@ Frequency (Hz) Array. First element indicate the array length
.word 32768, 440, 0, 550

@ @ 0 means harmony is not needed for that poisition
@ song_pitch2_tosend:
@ .word 3, 0, 220, 0

@ Duration divisor. If it not a rest, 4 = 0.25s, 2 = 0.5s, 1 = 1s
@ If it is a rest, 12000 = 0.25s, 48000 = 1s
@ This is to fit the foolish sequencer function I designed before
rest_time_tosend:
.word 3, 1, 12000, 1

array_pointer:
.word 0
