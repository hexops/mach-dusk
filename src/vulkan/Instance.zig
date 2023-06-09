const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const vk = @import("vulkan");
const Base = @import("Base.zig");
const Surface = @import("Surface.zig");
const global = @import("global.zig");
const Manager = @import("../helper.zig").Manager;

pub const Dispatch = vk.InstanceWrapper(.{
    .createDevice = true,
    .createXlibSurfaceKHR = true,
    .destroyInstance = true,
    .enumerateDeviceExtensionProperties = true,
    .enumerateDeviceLayerProperties = true,
    .enumeratePhysicalDevices = true,
    .getDeviceProcAddr = true,
    .getPhysicalDeviceFeatures = true,
    .getPhysicalDeviceProperties = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
});

const Instance = @This();

manager: Manager(Instance) = .{},
allocator: std.mem.Allocator,
base: Base,
dispatch: Dispatch,
instance: vk.Instance,

pub fn init(desc: *const gpu.Instance.Descriptor, allocator: std.mem.Allocator) !Instance {
    _ = desc;

    const base = try Base.init(allocator);
    const app_info = vk.ApplicationInfo{
        .application_version = 0,
        .engine_version = 0,
        .api_version = vk.makeApiVersion(0, 1, 3, 0),
    };

    const layers = try getLayers(base);
    defer allocator.free(layers);

    const extensions = try getExtensions(base);
    defer allocator.free(extensions);

    const instance = try base.createInstance(.{
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(layers.len),
        .pp_enabled_layer_names = layers.ptr,
        .enabled_extension_count = @intCast(extensions.len),
        .pp_enabled_extension_names = extensions.ptr,
    });
    const dispatch = try Dispatch.load(instance, base.getInstanceProcAddr());

    return .{
        .allocator = allocator,
        .base = base,
        .dispatch = dispatch,
        .instance = instance,
    };
}

pub fn deinit(instance: *Instance) void {
    instance.dispatch.destroyInstance(instance.instance, null);
    instance.base.deinit();
}

pub fn createSurface(instance: *Instance, desc: *const gpu.Surface.Descriptor) !Surface {
    return Surface.init(instance, desc);
}

fn getLayers(base: Base) ![]const [*:0]const u8 {
    const required_layers = &[_][*:0]const u8{global.validation_layer};

    var layers = try std.ArrayList([*:0]const u8).initCapacity(base.allocator, required_layers.len);
    errdefer layers.deinit();

    var count: u32 = 0;
    _ = try base.dispatch.enumerateInstanceLayerProperties(&count, null);

    var available_layers = try base.allocator.alloc(vk.LayerProperties, count);
    defer base.allocator.free(available_layers);
    _ = try base.dispatch.enumerateInstanceLayerProperties(&count, available_layers.ptr);

    for (required_layers) |ext| {
        for (available_layers[0..count]) |available| {
            if (std.mem.eql(u8, std.mem.sliceTo(ext, 0), std.mem.sliceTo(&available.layer_name, 0))) {
                layers.appendAssumeCapacity(ext);
                break;
            }
        } else {
            std.log.warn("unable to find layer: {s}", .{ext});
        }
    }

    return layers.toOwnedSlice();
}

fn getExtensions(base: Base) ![]const [*:0]const u8 {
    const required_platform_extensions = switch (builtin.os.tag) {
        .linux => &[_][*:0]const u8{
            vk.extension_info.khr_xlib_surface.name,
            vk.extension_info.khr_xcb_surface.name,
            vk.extension_info.khr_wayland_surface.name,
        },
        .windows => &.{vk.extension_info.khr_win_32_keyed_mutex.name},
        .macos, .ios => &.{vk.extension_info.ext_metal_surface.name},
        else => if (builtin.target.abi == .android)
            &.{vk.extension_info.khr_android_surface.name}
        else
            @compileError("unsupported platform"),
    };
    const required_extensions = required_platform_extensions ++ &[_][*:0]const u8{
        vk.extension_info.khr_surface.name,
    };

    var extensions = try std.ArrayList([*:0]const u8).initCapacity(base.allocator, required_extensions.len);
    errdefer extensions.deinit();

    var count: u32 = 0;
    _ = try base.dispatch.enumerateInstanceExtensionProperties(null, &count, null);

    var available_extensions = try base.allocator.alloc(vk.ExtensionProperties, count);
    defer base.allocator.free(available_extensions);
    _ = try base.dispatch.enumerateInstanceExtensionProperties(null, &count, available_extensions.ptr);

    for (required_extensions) |ext| {
        for (available_extensions[0..count]) |available| {
            if (std.mem.eql(u8, std.mem.sliceTo(ext, 0), std.mem.sliceTo(&available.extension_name, 0))) {
                extensions.appendAssumeCapacity(ext);
                break;
            }
        } else {
            std.log.warn("unable to find extension: {s}", .{ext});
        }
    }

    return extensions.toOwnedSlice();
}
