const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const linux = std.os.linux;
const posix = std.posix;
const meta = std.meta;

pub const c = @cImport(@cInclude("linux/uinput.h"));
const DeviceSpec = @import("getevent/Parser.zig").DeviceSpec;

alloc: mem.Allocator,
dev: fs.File,
setup: *c.uinput_setup,

const Self = @This();

pub fn getSetup(spec: DeviceSpec) c.uinput_setup {
    var res: c.uinput_setup = .{
        .id = .{
            .bustype = spec.bus,
            .product = spec.product,
            .vendor = spec.vendor,
            .version = spec.version,
        },
    };
    @memcpy(res.name[0..spec.name.len], spec.name);
    return res;
}

inline fn ioctlHandle(dev: fs.File) usize {
    return @as(usize, @bitCast(@as(isize, dev.handle)));
}

pub const Error = error{
    SyscallErr,
};

inline fn errnoToErr(rc: usize) Error!void {
    return switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => Error.SyscallErr,
    };
}

pub fn fromDeviceSpec(al: mem.Allocator, spec: DeviceSpec) !Self {
    const dev = try fs.openFileAbsolute("/dev/uinput", .{
        .mode = .write_only,
        .lock_nonblocking = true,
    });

    const setup = try al.create(c.uinput_setup);
    setup.* = getSetup(spec);

    for (spec.normal_events.arr.items) |evd| {
        const code, const event = evd;
        const bit = switch (code) {
            c.EV_KEY => c.UI_SET_KEYBIT,
            c.EV_REL => c.UI_SET_RELBIT,
            // c.EV_ABS => c.UI_SET_ABSBIT, (this is specially handled by the parser)
            c.EV_MSC => c.UI_SET_MSCBIT,
            c.EV_LED => c.UI_SET_LEDBIT,
            c.EV_SND => c.UI_SET_SNDBIT,
            c.EV_FF => c.UI_SET_FFBIT,
            c.EV_SW => c.UI_SET_SWBIT,
            else => unreachable,
        };

        try errnoToErr(linux.syscall3(.ioctl, ioctlHandle(dev), c.UI_SET_EVBIT, code));
        try errnoToErr(linux.syscall3(.ioctl, ioctlHandle(dev), bit, event));
    }

    if (spec.abs_events.arr.items.len > 0) {
        if (spec.abs_code.? != c.EV_ABS) unreachable;
        try errnoToErr(linux.syscall3(.ioctl, ioctlHandle(dev), c.UI_SET_EVBIT, c.EV_ABS));

        for (spec.abs_events.arr.items) |evd| {
            var abs_setup: c.uinput_abs_setup = .{
                .absinfo = .{
                    .flat = evd.flat,
                    .fuzz = evd.fuzz,
                    .maximum = evd.max,
                    .minimum = evd.min,
                    .resolution = evd.resolution,
                    .value = evd.value,
                },
                .code = evd.code,
            };

            try errnoToErr(linux.syscall3(.ioctl, ioctlHandle(dev), c.UI_SET_ABSBIT, abs_setup.code));
            try errnoToErr(linux.syscall3(.ioctl, ioctlHandle(dev), c.UI_ABS_SETUP, @intFromPtr(&abs_setup)));
        }
    }

    const Props = enum {
        INPUT_PROP_POINTER,
        INPUT_PROP_DIRECT,
        INPUT_PROP_BUTTONPAD,
        INPUT_PROP_SEMI_MT,
        INPUT_PROP_TOPBUTTONPAD,
        INPUT_PROP_POINTING_STICK,
        INPUT_PROP_ACCELEROMETER,
        INPUT_PROP_MAX,
        INPUT_PROP_CNT,
    };

    for (spec.input_props.arr.items) |prop| {
        const propt = meta.stringToEnum(Props, prop).?;
        const prop_id = switch (propt) {
            inline else => |e| @field(c, @tagName(e)),
        };
        try errnoToErr(linux.syscall3(.ioctl, ioctlHandle(dev), c.UI_SET_PROPBIT, @intCast(prop_id)));
    }

    try errnoToErr(linux.syscall3(.ioctl, ioctlHandle(dev), c.UI_DEV_SETUP, @intFromPtr(setup)));
    try errnoToErr(linux.syscall2(.ioctl, ioctlHandle(dev), c.UI_DEV_CREATE));

    var dname: [16:0]u8 = undefined;
    try errnoToErr(linux.syscall3(.ioctl, ioctlHandle(dev), c.UI_GET_SYSNAME(@sizeOf(@TypeOf(dname))), @intFromPtr(&dname)));

    std.debug.print("Created device: {s}\n", .{dname});

    return .{
        .alloc = al,
        .dev = dev,
        .setup = setup,
    };
}

pub inline fn emit(self: Self, ev: @Vector(2, u16), data: u32) void {
    const ie: c.input_event = .{
        .code = ev[1],
        .type = ev[0],
        .value = @bitCast(data),
        .time = .{
            .tv_sec = 0,
            .tv_usec = 0,
        },
    };

    _ = self.dev.write(mem.asBytes(&ie)) catch unreachable;
}

pub fn deinit(self: Self) void {
    _ = linux.syscall2(.ioctl, @as(usize, @bitCast(@as(isize, self.dev.handle))), c.UI_DEV_DESTROY);
    self.dev.close();
    self.alloc.destroy(self.setup);
}
