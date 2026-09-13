const std = @import("std");

fn readU16Little(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(
        u16,
        bytes[offset..][0..2],
        .little,
    );
}

fn readU32Little(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(
        u32,
        bytes[offset..][0..4],
        .little,
    );
}

fn programTypeName(program_type: u32) []const u8 {
    return switch (program_type) {
        0 => "NULL",
        1 => "LOAD",
        2 => "DYNAMIC",
        3 => "INTERP",
        4 => "NOTE",
        5 => "SHLIB",
        6 => "PHDR",
        7 => "TLS",
        0x6474e550 => "GNU_EH_FRAME",
        0x6474e551 => "GNU_STACK",
        0x6474e552 => "GNU_RELRO",
        else => "UNKNOWN",
    };
}

fn printProgramFlags(flags: u32) void {
    std.debug.print(
        "{s}{s}{s}",
        .{
            if ((flags & 4) != 0) "R" else "-",
            if ((flags & 2) != 0) "W" else "-",
            if ((flags & 1) != 0) "X" else "-",
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var file = try std.Io.Dir.openFile(
        std.Io.Dir.cwd(),
        io,
        "zig-out/bin/nrf52-blink.elf",
        .{ .mode = .read_only },
    );
    defer file.close(io);

    var read_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const reader = &file_reader.interface;

    const elf_header = try std.elf.Header.read(reader);

    std.debug.print("ELF class: {s}\n", .{
        if (elf_header.is_64) "ELF64" else "ELF32",
    });
    std.debug.print("Endianness: {s}\n", .{
        if (elf_header.endian == .little) "little" else "big",
    });
    std.debug.print("Entry point:             0x{x}\n", .{elf_header.entry});
    std.debug.print("Program-header offset:   0x{x}\n", .{elf_header.phoff});
    std.debug.print("Program-header size:     0x{x}\n", .{elf_header.phentsize});
    std.debug.print("Program-header count:    {}\n", .{elf_header.phnum});
    std.debug.print("Section-header offset:   0x{x}\n", .{elf_header.shoff});
    std.debug.print("Section-header size:     0x{x}\n", .{elf_header.shentsize});
    std.debug.print("Section-header count:    {}\n", .{elf_header.shnum});
    std.debug.print("Section-name table:      {}\n", .{elf_header.shstrndx});

    if (elf_header.is_64) {
        std.debug.print("This diagnostic currently handles ELF32 only.\n", .{});
        return;
    }

    if (elf_header.endian != .little) {
        std.debug.print("This diagnostic currently handles little-endian ELF only.\n", .{});
        return;
    }

    if (elf_header.phentsize < 32) {
        std.debug.print(
            "Invalid ELF32 program-header size: {}\n",
            .{elf_header.phentsize},
        );
        return;
    }

    std.debug.print("\nProgram headers:\n", .{});
    std.debug.print(
        "  #  Type       Offset     VirtAddr   PhysAddr   FileSize   MemSize    Flags Align\n",
        .{},
    );

    var minimum_load_address: ?u32 = null;
    var maximum_load_address: u32 = 0;

    var index: usize = 0;
    while (index < elf_header.phnum) : (index += 1) {
        const header_offset =
            elf_header.phoff +
            @as(u64, @intCast(index)) * elf_header.phentsize;

        // Seek using the buffered file reader so its internal state is reset.
        try file_reader.seekTo(header_offset);

        var raw: [32]u8 = undefined;
        try reader.readSliceAll(&raw);

        const program_type = readU32Little(&raw, 0x00);
        const file_offset = readU32Little(&raw, 0x04);
        const virtual_address = readU32Little(&raw, 0x08);
        const physical_address = readU32Little(&raw, 0x0c);
        const file_size = readU32Little(&raw, 0x10);
        const memory_size = readU32Little(&raw, 0x14);
        const flags = readU32Little(&raw, 0x18);
        const alignment = readU32Little(&raw, 0x1c);

        std.debug.print(
            "  {d:2} {s:10} 0x{x:0>8} 0x{x:0>8} 0x{x:0>8} " ++
                "0x{x:0>8} 0x{x:0>8} ",
            .{
                index,
                programTypeName(program_type),
                file_offset,
                virtual_address,
                physical_address,
                file_size,
                memory_size,
            },
        );

        printProgramFlags(flags);
        std.debug.print("   0x{x}\n", .{alignment});

        // PT_LOAD
        if (program_type == 1 and file_size != 0) {
            const start = physical_address;
            const end = physical_address + file_size;

            if (minimum_load_address == null or
                start < minimum_load_address.?)
            {
                minimum_load_address = start;
            }

            if (end > maximum_load_address) {
                maximum_load_address = end;
            }

            if (file_offset == 0) {
                std.debug.print(
                    "       WARNING: LOAD includes file offset zero; " ++
                        "this includes the ELF header.\n",
                    .{},
                );
            }
        }
    }

    if (minimum_load_address) |minimum| {
        std.debug.print(
            "\nLOAD image range: 0x{x} through 0x{x}\n",
            .{ minimum, maximum_load_address },
        );
        std.debug.print(
            "Flat address span: 0x{x} bytes\n",
            .{maximum_load_address - minimum},
        );
    }

    if (elf_header.shentsize < 40) {
        std.debug.print(
            "\nInvalid ELF32 section-header size: {}\n",
            .{elf_header.shentsize},
        );
        return;
    }

    std.debug.print("\nSection headers:\n", .{});
    std.debug.print(
        "  #  Type       Address    Offset     Size       Flags NameOffset\n",
        .{},
    );

    index = 0;
    while (index < elf_header.shnum) : (index += 1) {
        const header_offset =
            elf_header.shoff +
            @as(u64, @intCast(index)) * elf_header.shentsize;

        try file_reader.seekTo(header_offset);

        var raw: [40]u8 = undefined;
        try reader.readSliceAll(&raw);

        const name_offset = readU32Little(&raw, 0x00);
        const section_type = readU32Little(&raw, 0x04);
        const flags = readU32Little(&raw, 0x08);
        const address = readU32Little(&raw, 0x0c);
        const file_offset = readU32Little(&raw, 0x10);
        const size = readU32Little(&raw, 0x14);
        const alignment = readU32Little(&raw, 0x20);

        std.debug.print(
            "  {d:2} {s:10} 0x{x:0>8} 0x{x:0>8} 0x{x:0>8} " ++
            "{s}{s}{s}   0x{x}  align=0x{x}\n",
            .{
                index,
                sectionTypeName(section_type),
                address,
                file_offset,
                size,
                if ((flags & 0x2) != 0) "A" else "-", // SHF_ALLOC
                    if ((flags & 0x1) != 0) "W" else "-", // SHF_WRITE
                        if ((flags & 0x4) != 0) "X" else "-", // SHF_EXECINSTR
                            name_offset,
                            alignment,
                        },
                        );
    }

}

fn sectionTypeName(section_type: u32) []const u8 {
    return switch (section_type) {
        0 => "NULL",
        1 => "PROGBITS",
        2 => "SYMTAB",
        3 => "STRTAB",
        4 => "RELA",
        5 => "HASH",
        6 => "DYNAMIC",
        7 => "NOTE",
        8 => "NOBITS",
        9 => "REL",
        11 => "DYNSYM",
        14 => "INIT_ARRAY",
        15 => "FINI_ARRAY",
        16 => "PREINIT_ARRAY",
        17 => "GROUP",
        18 => "SYMTAB_SHNDX",
        else => "UNKNOWN",
    };
}
