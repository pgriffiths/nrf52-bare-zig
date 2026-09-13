# nrf52-bare-zig
Demonstrate building bare-metal application for the Adafruit nRF52832 with Zig 0.16 and without external dependencies.

Flash programming tool is adafruit-nrfutil, a Python command line tool that talks over USB/serial. 


# Setup

Feather board was updated with the latest boot loader:

1. Download boot-loader:  See https://github.com/adafruit/Adafruit_nRF52_Bootloader/releases
1. Flash boot loader: adafruit-nrfutil --verbose dfu serial --package ~/Downloads/feather_nrf52832_bootloader-0.9.2_s132_6.1.1.zip -p /dev/cu.usbserial-0209DE2C -b 115200 --singleba
nk --touch 1200

Note that the boot-loader version will change the linder settings including, critically, the starting address of the vector table. For recent boot-loaders, the vector table with initial stack pointer and the location of the start of the application (reset_handler) begin at 0x26000.

# Build and Flash
The build through build.zig targets the Arm Cortex M4 (thumb architecture) and enables the hardware floating-point support.

Run `zig build' to build the elf and associated hex and bin files. Run `zig build upload' to build, package, and write to flash. The second two commands for packaging and uploading can be run at the command line directly as well

1. adafruit-nrfutil dfu genpkg --dev-type 0x0052 --dev-revision 0xADAF  --sd-req 0xFFFE  --application zig-out/bin/nrf52-blink.hex blink_package.zip
1. adafruit-nrfutil dfu serial --package blink_package.zip --port /dev/cu.usbserial-0209DE2C --singlebank --baudrate 115200

The name of the usbserial seems to be fixed.

Open the terminal at 115200 baud to see print output. For example:
 tio -b 115200 /dev/cu.usbserial-0209DE2C

Note the act of opening the serial port appears to reset the board.

# Details and Issues Encountered
Unneeded segments appear in the ELF output unless the program headers (PHDRS) are explicitly given in the linker file. The bin file from objcopy would correctly have only the expected flash segments and could be passed to adafruit-nrfutil for upload. The hex file would upload and fail to run. Inspecting the hex file output and the final bin packaged up in the zip file by adafruit-nrfutil revealed content before the expected start of .text at 0x26000.

Initializing the program reveals interesting details necessary to setup hardware and load memory without any OS or board-support package. The registration of the vector table and enablement of FPU appear to be unnecessary if they are already set by the boot loader. Initializing variables by copying from flash to RAM is however a necessary step.


