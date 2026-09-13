const std = @import("std");

pub fn build(b: *std.Build) void {
    // 1. Define the cross-compilation target query
    const target_query = std.Target.Query{
        .cpu_arch = .thumb,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 },
        .cpu_features_add = std.Target.arm.featureSet(&.{ .vfp4d16sp, }),
        .os_tag = .freestanding,
        .abi = .eabihf, // Hard-float for Cortex-M4F
    };

    // 2. Resolve the target query into a build-graph compliant ResolvedTarget
    const target = b.resolveTargetQuery(target_query);

    // 3. Set the optimization mode (ReleaseSmall is perfect for embedded bare-metal)
    const optimize = .ReleaseSmall;

    // 4. Create the root module (This is where target and source now live in 0.16.0)
    const blink_module = b.createModule(.{
        .root_source_file = b.path("src/main_min.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 5. Setup the binary artifact passing only the module
    const exe = b.addExecutable(.{
        .name = "nrf52-blink.elf",
        .root_module = blink_module,
    });

    // 6. Assign our custom linker script
    exe.setLinkerScript(b.path("linker.ld"));

    // 7. Expose the built ELF file to the user
    b.installArtifact(exe);

    // 8. Convert the ELF file to an Intel HEX file for flashing tools
    const objcopy = exe.addObjCopy(.{ .format = .hex });
    const install_hex = b.addInstallBinFile(objcopy.getOutput(), "nrf52-blink.hex");
    b.getInstallStep().dependOn(&install_hex.step);


    // Convert ELF directly to a flat binary.
    const make_bin = exe.addObjCopy(.{ .format = .bin, });
    const install_bin = b.addInstallBinFile(
        make_bin.getOutput(),
        "nrf52-blink.bin",
    );
    b.getInstallStep().dependOn(&install_bin.step);

    // -----------------------------------------------------------------------------
    // Create the Adafruit DFU package
    // -----------------------------------------------------------------------------

    const port = b.option(
        []const u8,
        "port",
        "Serial port used to upload the DFU package",
    ) orelse "/dev/cu.usbserial-0209DE2C";

    const baud = b.option(
        u32,
        "baud",
        "Serial upload baud rate",
    ) orelse 115200;

    const installed_hex_path = b.getInstallPath(
        .bin,
        "nrf52-blink.hex",
    );

    const package_path = b.pathFromRoot("blink_package.zip");

    const package_cmd = b.addSystemCommand(&.{
        "adafruit-nrfutil",
        "dfu",
        "genpkg",
        "--dev-type",
        "0x0052",
        "--dev-revision",
        "0xADAF",
        "--sd-req",
        "0xFFFE",
        "--application",
    });

    package_cmd.addArg(installed_hex_path);
    package_cmd.addArg(package_path);

    // Ensure zig-out/bin/nrf52-blink.hex exists before packaging it.
    package_cmd.step.dependOn(b.getInstallStep());

    const package_step = b.step(
        "package",
        "Create blink_package.zip for Adafruit nRF52 DFU",
    );
    package_step.dependOn(&package_cmd.step);

    // -----------------------------------------------------------------------------
    // Upload the DFU package
    // -----------------------------------------------------------------------------
    const upload_cmd = b.addSystemCommand(&.{
        "adafruit-nrfutil",
        "dfu",
        "serial",
        "--package",
    });

    upload_cmd.addArg(package_path);
    upload_cmd.addArgs(&.{
        "--port",
        port,
        "--singlebank",
        "--baudrate",
    });
    upload_cmd.addArg(b.fmt("{d}", .{baud}));

    // Running the upload step always regenerates the package first.
    upload_cmd.step.dependOn(&package_cmd.step);

    const upload_step = b.step(
        "upload",
        "Package and upload the application over serial DFU",
    );
    upload_step.dependOn(&upload_cmd.step);
}
