MEMORY
{
  /* Adafruit nRF52832 application space with the S132 SoftDevice present. */
  FLASH (rx) :
    ORIGIN = 0x00026000,
    LENGTH = 284K

  /*
   * RAM below 0x20003600 is reserved for the SoftDevice.
   * RAM ends at 0x20010000 on the nRF52832.
   */
  RAM (rwx) :
    ORIGIN = 0x20003600,
    LENGTH = 0x20010000 - 0x20003600
}

ENTRY(_start)

/*
 * Define the ELF loadable segments explicitly.
 *
 * FILEHDR and PHDRS are intentionally not specified here. Therefore, the ELF
 * file header and program-header table are not included in a PT_LOAD segment.
 *
 * ELF segment flags:
 *   4 = readable
 *   2 = writable
 *   1 = executable
 */
PHDRS
{
  flash PT_LOAD FLAGS(5); /* Read + execute */
  ram   PT_LOAD FLAGS(6); /* Read + write */
}

SECTIONS
{
  /* 1. Vector table at the beginning of application flash. */
  .vectors :
  {
    . = ALIGN(4);
    KEEP(*(.vectors))
    . = ALIGN(4);
  } > FLASH :flash

  /* 2. Executable code and read-only data. */
  .text :
  {
    . = ALIGN(4);

    *(.text*)
    *(.rodata*)

    . = ALIGN(4);
  } > FLASH :flash

  /*
   * ARM exception-unwind data must remain in separate output sections because
   * .ARM.exidx has the special ELF section type SHT_ARM_EXIDX.
   */
  .ARM.extab :
  {
    . = ALIGN(4);
    *(.ARM.extab*)
    *(.gnu.linkonce.armextab.*)
    . = ALIGN(4);
  } > FLASH :flash

  .ARM.exidx :
  {
    . = ALIGN(4);
    __exidx_start = .;

    *(.ARM.exidx*)
    *(.gnu.linkonce.armexidx.*)

    __exidx_end = .;
    . = ALIGN(4);
  } > FLASH :flash
 
  /*
   * 3. Variables with nonzero initial values.
   *
   * Their initial bytes are stored in flash, but their runtime addresses are
   * in RAM. Startup code copies [_sidata, ...] to [_sdata, _edata).
   */
  _sidata = LOADADDR(.data);

  .data :
  {
    . = ALIGN(4);
    _sdata = .;

    *(.data*)

    . = ALIGN(4);
    _edata = .;
  } > RAM AT > FLASH :ram

  /*
   * 4. Zero-initialized variables.
   *
   * NOLOAD means this section occupies RAM but does not need bytes in the
   * firmware image. Startup code clears [_sbss, _ebss).
   */
  .bss (NOLOAD) :
  {
    . = ALIGN(4);
    _sbss = .;

    *(.bss*)
    *(COMMON)

    . = ALIGN(4);
    _ebss = .;
  } > RAM :ram

  /* The initial stack pointer is the first address above usable RAM. */
  _estack = ORIGIN(RAM) + LENGTH(RAM);
}
