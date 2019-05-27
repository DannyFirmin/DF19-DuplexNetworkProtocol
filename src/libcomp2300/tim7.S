.syntax unified

@ ------------------------ TIM7 ------------------------
@ Timer 7 features a 16-bit prescaler and a 16-bit counter.
@ The prescaler divides the main clock (which runs at 80MHz according to definition in HAL),
@ and the counter counts up according to the divided clock.
@ When the counter counts up to the reload value,
@ an update event is triggered and an interrupt is fired.

@ --------------------- Module Interface --------------------
.global tim7_init, TIM7_IRQHandler, custom_sync, reset_sender

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
  mov r1, #4
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
  bl red_led_toggle
  ldr r1, = array_pointer
  ldr r0, [r1]
  lsl r2, r0, #2
  ldr r1, =song_pitch_tosend
  ldr r0, [r1, r2]
  bl send_bit

  ldr r1, = array_pointer
  ldr r0, [r1]
  add r0, 1
  str r0, [r1]

  ldr r1, = song_pitch_tosend
  ldr r2, [r1] @ the length of the array
  cmp r0, r2
  IT hi
  blhi tim7_stop

  @ Clear interrupt (Section 29.4.4)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_SR
  mov r2, 0
  bl clear_bit
  bl sync
  pop {lr,r4-r10}
  bx lr
.size TIM7_IRQHandler, .-TIM7_IRQHandler


.type send_bit, %function
@ --parameters--
@ r0: song pitch to send
send_bit:
  push {lr, r4-r6}
  mov r5, r0 @ r5 will always store the pitch until function returns
  mov r4, #15 @ left most bit first, position 15
  mov r6, 0 @ 0 means sending pitch, 1 means sending checksum
  keep_sending:
  mov r0, r5
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
  push {r4}
  GPIOx_ODR_set E, 13
  mov r0, #12
  bl custom_sync
  GPIOx_ODR_clear E, 13
  bl sync
  pop {r4}
  sub r4, 1
  @ if r4 >= 0, continue
  cmp r4, 0
  bge keep_sending

  cmp r6, 1 @ 1 means don't need to calculate the checksum of checksum
  beq send_end
  @ Finishing
  mov r0, #24
  bl custom_sync
  mov r0, r5 @ load the 16 bit sent data
  bl checksum_xor
  mov r5, r0 @ send the checksum result
  mov r6, 1
  mov r4, #15
  b keep_sending
  send_end:
  pop {lr, r4-r6}
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

.type reset_sender, %function
@ To make sure a interrupt is fully executed
@ --parameters--
@ r0: sync how many time
reset_sender:
  push {lr}
  ldr r1, =array_pointer
  ldr r0, [r1]
  sub r0, 1
  str r0, [r1]
  
  @ Clear interrupt (Section 29.4.4)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_SR
  mov r2, 0
  bl clear_bit

  mov r4, 0
  mov r5, 0
  mov r6, 0

  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_CR1
  mov r2, 0
  bl set_bit

  @ RESET BOARD
  ldr r0, =0xE000ED0C
  mov r2, #16
  ldr r3, =0x05FA
  lsl r3, r2
  orr r3, 0b100
  str r3, [r0]
  bl sync
  pop {lr}
  bx lr
.size reset_sender, .-reset_sender

.type tim7_stop, %function
tim7_stop:
  push {lr}

  @ disable timer 7  (Section 29.4.1s)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_CR1
  mov r2, 0
  bl clear_bit

  GPIOx_ODR_clear E, 14
  bl sync @ Fire to the control line
  pop {lr}
  bx lr
.size tim7_stop, .-tim7_stop
@ Sender's Memory
.data

song_pitch_tosend:
@ Frequency (Hz) Array. First element indicate the array length
  .word 9, 100, 200, 300, 400, 500, 600, 700, 800, 900

array_pointer:
  .word 0
