const UARTE0_BASE: usize = 0x4000_2000;

fn reg32(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

// Tasks
const UARTE_TASKS_STARTTX = reg32(UARTE0_BASE + 0x008);
const UARTE_TASKS_STOPTX  = reg32(UARTE0_BASE + 0x00C);

// Events
const UARTE_EVENTS_ENDTX      = reg32(UARTE0_BASE + 0x120);
const UARTE_EVENTS_TXSTOPPED  = reg32(UARTE0_BASE + 0x158);

// Configuration
const UARTE_ENABLE    = reg32(UARTE0_BASE + 0x500);
const UARTE_PSEL_RTS  = reg32(UARTE0_BASE + 0x508);
const UARTE_PSEL_TXD  = reg32(UARTE0_BASE + 0x50C);
const UARTE_PSEL_CTS  = reg32(UARTE0_BASE + 0x510);
const UARTE_PSEL_RXD  = reg32(UARTE0_BASE + 0x514);
const UARTE_BAUDRATE  = reg32(UARTE0_BASE + 0x524);

// EasyDMA transmit registers
const UARTE_TXD_PTR     = reg32(UARTE0_BASE + 0x544);
const UARTE_TXD_MAXCNT  = reg32(UARTE0_BASE + 0x548);
const UARTE_TXD_AMOUNT  = reg32(UARTE0_BASE + 0x54C);

const UARTE_CONFIG = reg32(UARTE0_BASE + 0x56C);

// GPIO
const GPIO_BASE: usize = 0x5000_0000;

fn gpioPinCnf(pin: u5) *volatile u32 {
    return reg32(GPIO_BASE + 0x700 + @as(usize, pin) * 4);
}

const UART_TX_PIN: u5 = 6; // P0.06: nRF52 TX -> CP2104 RX
const UART_RX_PIN: u5 = 8; // P0.08: nRF52 RX <- CP2104 TX

const PSEL_DISCONNECTED: u32 = 0xFFFF_FFFF;

pub fn initializeUart() void {
    // Disable the shared UART0/UARTE0 peripheral while configuring it.
    UARTE_ENABLE.* = 0;

    // PIN_CNF fields:
    // bit 0     DIR:   0=input, 1=output
    // bit 1     INPUT: 0=connect, 1=disconnect
    // bits 2:3  PULL:  0=disabled, 3=pull-up
    // bits 8:10 DRIVE: 0=S0S1
    // bits 16:17 SENSE: 0=disabled

    // TX: output, input buffer disconnected, no pull, standard drive.
    gpioPinCnf(UART_TX_PIN).* =
        (1 << 0) | // DIR=Output
        (1 << 1);  // INPUT=Disconnect

    // RX: input, input buffer connected, pull-up enabled.
    gpioPinCnf(UART_RX_PIN).* =
        (0 << 0) | // DIR=Input
        (0 << 1) | // INPUT=Connect
        (3 << 2);  // PULL=Pullup

    // Select GPIO pins. The nRF52832 has only port 0, so these are
    // simply the P0 pin numbers.
    UARTE_PSEL_TXD.* = UART_TX_PIN;
    UARTE_PSEL_RXD.* = UART_RX_PIN;

    // Hardware flow-control pins are unused.
    UARTE_PSEL_RTS.* = PSEL_DISCONNECTED;
    UARTE_PSEL_CTS.* = PSEL_DISCONNECTED;

    // 115200 baud.
    UARTE_BAUDRATE.* = 0x01D7_E000;

    // Hardware flow control disabled, no parity, one stop bit.
    UARTE_CONFIG.* = 0;

    // Clear stale event state left by a previous execution/bootloader.
    UARTE_EVENTS_ENDTX.* = 0;
    UARTE_EVENTS_TXSTOPPED.* = 0;

    // ENABLE=8 selects UARTE mode rather than legacy UART mode.
    UARTE_ENABLE.* = 8;
}

// EasyDMA support
const UART_BUFFER_SIZE: usize = 256;
const UART_DMA_MAX_COUNT: usize = 255;

// Global storage is placed in RAM. initializeMemory() must clear .bss
// before these variables are used.
var uart_tx_buffer: [UART_BUFFER_SIZE]u8 = undefined;
var uart_tx_count: usize = 0;

fn uartDmaTransmit(data: []const u8) void {
    if (data.len == 0) {
        return;
    }

    // nRF52832 UARTE TXD.MAXCNT is 8 bits.
    if (data.len > UART_DMA_MAX_COUNT) {
        @panic("UARTE DMA transaction exceeds 255 bytes");
    }

    // EasyDMA requires the data to be in Data RAM.
    const address = @intFromPtr(data.ptr);

    UARTE_EVENTS_ENDTX.* = 0;

    UARTE_TXD_PTR.* = @as(u32, @intCast(address));
    UARTE_TXD_MAXCNT.* = @as(u32, @intCast(data.len));

    // Ensure all writes to the RAM buffer are visible before starting DMA.
    asm volatile ("dmb" ::: .{ .memory = true});

    UARTE_TASKS_STARTTX.* = 1;

    while (UARTE_EVENTS_ENDTX.* == 0) {
        asm volatile ("dmb" ::: .{ .memory = true});
    }

    // Optional diagnostic check.
    if (UARTE_TXD_AMOUNT.* != data.len) {
        // Replace this with your error indication if desired.
        @panic("Incomplete UARTE transmission");
    }

    UARTE_EVENTS_ENDTX.* = 0;
}

pub fn uartFlush() void {
    var offset: usize = 0;

    while (offset < uart_tx_count) {
        const remaining = uart_tx_count - offset;
        const amount = @min(remaining, UART_DMA_MAX_COUNT);

        uartDmaTransmit(
            uart_tx_buffer[offset .. offset + amount],
        );

        offset += amount;
    }

    uart_tx_count = 0;
}

pub fn uartWrite(data: []const u8) void {
    var source_offset: usize = 0;

    while (source_offset < data.len) {
        const available = UART_BUFFER_SIZE - uart_tx_count;
        const remaining = data.len - source_offset;
        const amount = @min(available, remaining);

        @memcpy(
            uart_tx_buffer[uart_tx_count .. uart_tx_count + amount],
            data[source_offset .. source_offset + amount],
        );

        uart_tx_count += amount;
        source_offset += amount;

        if (uart_tx_count == UART_BUFFER_SIZE) {
            uartFlush();
        }
    }
}

pub fn uartWriteLine(text: []const u8) void {
    uartWrite(text);
    uartWrite("\r\n");
    uartFlush();
}
