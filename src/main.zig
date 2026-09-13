const std = @import("std");
const uart = @import("uart_cp2104.zig");

extern const _estack: anyopaque;
extern var _sidata: u8;
extern var _sdata: u8;
extern var _edata: u8;

extern var _sbss: u8;
extern var _ebss: u8;

const Handler = *const fn () callconv(.c) noreturn;

pub const VectorTable = extern struct {
    initial_stack_pointer: *const anyopaque,
    reset_handler: Handler,
    nmi_handler: Handler,
    hard_fault_handler: Handler,
    memory_management_fault: Handler,
    bus_fault: Handler,
    usage_fault: Handler,
    reserved0: [4]u32,
    sv_call: Handler,
    debug_monitor: Handler,
    reserved1: u32,
    pend_sv: Handler,
    sys_tick: Handler,
};

export const vector_table: VectorTable
    align(256)
    linksection(".vectors") = .{
        .initial_stack_pointer = &_estack,
        .reset_handler = &_start,
        .nmi_handler = &defaultHandler,
        .hard_fault_handler = &defaultHandler,
        .memory_management_fault = &defaultHandler,
        .bus_fault = &defaultHandler,
        .usage_fault = &defaultHandler,
        .reserved0 = .{ 0, 0, 0, 0 },
        .sv_call = &defaultHandler,
        .debug_monitor = &defaultHandler,
        .reserved1 = 0,
        .pend_sv = &defaultHandler,
        .sys_tick = &defaultHandler,
    };

const GPIO_OUTSET: *volatile u32 = @ptrFromInt(0x50000508);
const GPIO_OUTCLR: *volatile u32 = @ptrFromInt(0x5000050C);
const LED_PIN_CNF: *volatile u32 = @ptrFromInt(0x50000700 + 17 * 4);

const LED_MASK: u32 = @as(u32, 1) << 17;

const DELAY_COUNTS_PER_SECOND: f32 = 5_000_000.0;

var on_time_sec: f32 = 1.25;
var off_time_sec: f32 = 2.75;

fn secondsToDelayCounts(seconds: f32) u32 {
    if (seconds <= 0.0) {
        return 0;
    }

    const counts = seconds * DELAY_COUNTS_PER_SECOND;
    return @intFromFloat(counts);
}

// Floating-point unit needs to be enabled
const SCB_CPACR: *volatile u32 = @ptrFromInt(0xE000_ED88);
const CP10_CP11_FULL_ACCESS: u32 = 0xF << 20;

fn enableFpu() void {
    SCB_CPACR.* |= CP10_CP11_FULL_ACCESS;

    // Ensure the permission change is visible before any FP instruction.
    asm volatile ("dsb");
    asm volatile ("isb");
}

// Ram with initialized variables needs to be copied from flash
// Ram with zero-initialized variables needs to be zero filled.
fn initializeMemory() void {
    // Copy initialized variables from their flash load addresses
    // to their RAM runtime addresses.
    var source_address = @intFromPtr(&_sidata);
    var destination_address = @intFromPtr(&_sdata);
    const data_end_address = @intFromPtr(&_edata);

    while (destination_address < data_end_address) {
        const source: *const u8 = @ptrFromInt(source_address);
        const destination: *volatile u8 = @ptrFromInt(destination_address);

        destination.* = source.*;

        source_address += 1;
        destination_address += 1;
    }

    // Initialize all uninitialized/static-zero variables to zero.
    var bss_address = @intFromPtr(&_sbss);
    const bss_end_address = @intFromPtr(&_ebss);

    while (bss_address < bss_end_address) {
        const destination: *volatile u8 = @ptrFromInt(bss_address);
        destination.* = 0;

        bss_address += 1;
    }
}

fn initGPIO() void {
    //
    // Set the output latch high before enabling the output.
    // The Feather's red LED on P0.17 is normally active-low.
    GPIO_OUTSET.* = LED_MASK;

    // DIR=Output; INPUT=Connect; PULL=Disabled; DRIVE=S0S1; SENSE=Disabled.
    LED_PIN_CNF.* = 1;

    GPIO_OUTCLR.* = LED_MASK; // Off 
}

const force_handler_test = false;

pub export fn _start() callconv(.c) noreturn {
    // Disable configurable-priority exceptions while setting up memory, FPU, and GPIO.
    // Disabled exceptions include:
    //
    // External peripheral interrupts
    // SysTick
    // PendSV
    // SVCall
    // Configurable fault handlers such as UsageFault
    // * does not mask NMI or HardFault.
    asm volatile ("cpsid i"); // "d" is disable

    // Tell Cortex-M4 that the active vector table starts at 0x26000
    const SCB_VTOR: *volatile u32 = @ptrFromInt(0xE000ED08);
    SCB_VTOR.* = 0x00026000;
    // Memory sync before proceeding
    asm volatile ("dsb" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
   
    // Floating-point power up    
    enableFpu();
    initializeMemory();
    initGPIO();

    // Re-enable exceptions
    asm volatile ("cpsie i"); // "d" is disable

    // Test the vector table
    if (force_handler_test) {
        asm volatile ("svc #0");
    }

    GPIO_OUTSET.* = LED_MASK; // On 
    delay(16_000_000);

    GPIO_OUTCLR.* = LED_MASK; // Off 
    delay(16_000_000);

    GPIO_OUTSET.* = LED_MASK; // On 
    delay(16_000_000);


    uart.initializeUart();

    uart.uartWriteLine("nRF52832 application started");
    uart.uartWriteLine("UARTE0 EasyDMA is active");
    
    while (true) {
        // Forceing these calucations to occur at runtiem
        const on_seconds = @as(*volatile f32, &on_time_sec).*;
        const off_seconds = @as(*volatile f32, &off_time_sec).*;

        const on_delay_counts = secondsToDelayCounts(on_seconds);
        const off_delay_counts = secondsToDelayCounts(off_seconds);
        
        GPIO_OUTCLR.* = LED_MASK; // LED off 
        delay(off_delay_counts);

        GPIO_OUTSET.* = LED_MASK; // LED on 
        delay(on_delay_counts);
        uart.uartWriteLine("Cycle");

    }
}

fn fault() callconv(.c) noreturn {
    // A fault produces a solid red LED.
    GPIO_OUTCLR.* = LED_MASK;
    LED_PIN_CNF.* = 1;

    while (true) {
        asm volatile ("nop");
    }
}

fn delay(cycles: u32) void {
    var remaining = cycles;
    while (remaining != 0) : (remaining -= 1) {
        asm volatile ("nop");
    }
}

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = msg;
    _ = error_return_trace;
    _ = ret_addr;
    fault();
}

fn blinkNumber(cnt: u32) void {
    while (true) {
        for (0..cnt) |_| {
            for (0..5) |_| {
                GPIO_OUTCLR.* = LED_MASK;
                delay(800_000);

                GPIO_OUTSET.* = LED_MASK;
                delay(800_000);
            }
            delay(8_000_000);
        }
        GPIO_OUTCLR.* = LED_MASK;
        delay(16_000_000);

    }

}
fn defaultHandler() callconv(.c) noreturn {
    while(true) {
        blinkNumber(4);
    }
}

pub export fn HardFault_Handler() callconv(.c) noreturn {
    while(true) {
        blinkNumber(2);
    }
}
