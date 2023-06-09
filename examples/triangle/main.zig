const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const gpu = @import("gpu");
const dusk = @import("dusk");
const objc = @import("objc.zig");
const shader = @embedFile("shader.wgsl");

pub const GPUInterface = dusk.Interface;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize GLFW
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    const hints = glfw.Window.Hints{ .client_api = .no_api, .cocoa_retina_framebuffer = true };
    const window = glfw.Window.create(640, 480, "Dusk Triangle", null, null, hints) orelse {
        std.log.err("failed to create GLFW window: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    };

    // Initialize GPU
    gpu.Impl.init(gpa.allocator());

    const instance = gpu.createInstance(null) orelse {
        std.log.err("failed to create GPU instance", .{});
        std.process.exit(1);
    };
    const surface = createSurfaceForWindow(instance, window);

    var response: RequestAdapterResponse = undefined;
    instance.requestAdapter(&gpu.RequestAdapterOptions{
        .compatible_surface = surface,
        .power_preference = .undefined,
        .force_fallback_adapter = false,
    }, &response, requestAdapterCallback);
    if (response.status != .success) {
        std.log.err("failed to create GPU adapter: {s}", .{response.message.?});
        std.process.exit(1);
    }

    var props: gpu.Adapter.Properties = undefined;
    response.adapter.getProperties(&props);
    std.log.info("found {s} backend on {s} adapter: {s}, {s}", .{
        props.backend_type.name(),
        props.adapter_type.name(),
        props.name,
        props.driver_description,
    });

    const device = response.adapter.createDevice(&.{
        .device_lost_callback = deviceLostCallback,
        .device_lost_userdata = null,
    }) orelse {
        std.log.err("failed to create GPU device", .{});
        std.process.exit(1);
    };
    defer device.release();
    device.setUncapturedErrorCallback({}, uncapturedErrorCallback);

    const framebuffer_size = window.getFramebufferSize();
    var swapchain_desc = gpu.SwapChain.Descriptor{
        .label = "swap chain",
        .usage = .{ .render_attachment = true },
        .format = .bgra8_unorm,
        .width = framebuffer_size.width,
        .height = framebuffer_size.height,
        .present_mode = .mailbox,
    };
    var swap_chain = device.createSwapChain(surface, &swapchain_desc);

    const vertex_module = device.createShaderModuleWGSL("vertex shader", shader);
    const fragment_module = device.createShaderModuleWGSL("fragment shader", shader);

    const blend = gpu.BlendState{
        .color = .{
            .dst_factor = .one,
        },
        .alpha = .{
            .dst_factor = .one,
        },
    };
    const color_target = gpu.ColorTargetState{
        .format = swapchain_desc.format,
        .blend = &blend,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const fragment = gpu.FragmentState.init(.{
        .module = fragment_module,
        .entry_point = "fragment_main",
        .targets = &.{color_target},
    });
    const vertex = gpu.VertexState{
        .module = vertex_module,
        .entry_point = "vertex_main",
    };
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .fragment = &fragment,
        .layout = null,
        .depth_stencil = null,
        .vertex = vertex,
        .multisample = .{},
        .primitive = .{},
    };

    // Reconfigure the swap chain with the new framebuffer width/height, otherwise e.g. the Vulkan
    // device would be lost after a resize.
    var next_swapchain_desc = swapchain_desc;
    window.setUserPointer(&next_swapchain_desc);
    window.setFramebufferSizeCallback((struct {
        fn callback(win: glfw.Window, width: u32, height: u32) void {
            const next_descriptor = win.getUserPointer(gpu.SwapChain.Descriptor).?;
            next_descriptor.width = width;
            next_descriptor.height = height;
        }
    }).callback);

    const pipeline = device.createRenderPipeline(&pipeline_descriptor);
    defer pipeline.release();

    vertex_module.release();
    fragment_module.release();

    const queue = device.getQueue();
    defer queue.release();

    while (!window.shouldClose()) {
        const pool = if (comptime builtin.target.isDarwin()) try objc.AutoReleasePool.init() else undefined;
        defer if (comptime builtin.target.isDarwin()) objc.AutoReleasePool.release(pool);

        glfw.pollEvents();
        if (!std.meta.eql(swapchain_desc, next_swapchain_desc)) {
            swap_chain.release();
            swap_chain = device.createSwapChain(surface, &next_swapchain_desc);
            swapchain_desc = next_swapchain_desc;
        }

        const view = swap_chain.getCurrentTextureView().?;
        const color_attachment = gpu.RenderPassColorAttachment{
            .view = view,
            .resolve_target = null,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .load_op = .clear,
            .store_op = .store,
        };

        const encoder = device.createCommandEncoder(null);
        const render_pass_info = gpu.RenderPassDescriptor.init(.{ .color_attachments = &.{color_attachment} });
        const pass = encoder.beginRenderPass(&render_pass_info);
        pass.setPipeline(pipeline);
        pass.draw(3, 1, 0, 0);
        pass.end();
        pass.release();

        var command = encoder.finish(null);
        encoder.release();

        queue.submit(&[_]*gpu.CommandBuffer{command});
        command.release();
        swap_chain.present();
        view.release();
        std.time.sleep(16 * std.time.ns_per_ms);
    }
}

pub fn createSurfaceForWindow(instance: *gpu.Instance, window: glfw.Window) *gpu.Surface {
    const glfw_options: glfw.BackendOptions = switch (builtin.target.os.tag) {
        .windows => .{ .win32 = true },
        .linux => .{ .x11 = true, .wayland = true },
        else => if (builtin.target.isDarwin()) .{ .cocoa = true } else .{},
    };
    const glfw_native = glfw.Native(glfw_options);

    const extension = if (glfw_options.win32) gpu.Surface.Descriptor.NextInChain{
        .from_windows_hwnd = &.{
            .hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?,
            .hwnd = glfw_native.getWin32Window(window),
        },
    } else if (glfw_options.x11) gpu.Surface.Descriptor.NextInChain{
        .from_xlib_window = &.{
            .display = glfw_native.getX11Display(),
            .window = glfw_native.getX11Window(window),
        },
    } else if (glfw_options.wayland) gpu.Surface.Descriptor.NextInChain{
        .from_wayland_window = &.{
            .display = glfw_native.getWaylandDisplay(),
            .surface = glfw_native.getWaylandWindow(window),
        },
    } else if (glfw_options.cocoa) blk: {
        const ns_window = glfw_native.getCocoaWindow(window);
        const ns_view = objc.msgSend(ns_window, "contentView", .{}, *anyopaque); // [nsWindow contentView]

        // Create a CAMetalLayer that covers the whole window that will be passed to CreateSurface.
        objc.msgSend(ns_view, "setWantsLayer:", .{true}, void); // [view setWantsLayer:YES]
        const layer = objc.msgSend(objc.objc_getClass("CAMetalLayer"), "layer", .{}, ?*anyopaque); // [CAMetalLayer layer]
        if (layer == null) @panic("failed to create Metal layer");
        objc.msgSend(ns_view, "setLayer:", .{layer.?}, void); // [view setLayer:layer]

        // Use retina if the window was created with retina support.
        const scale_factor = objc.msgSend(ns_window, "backingScaleFactor", .{}, f64); // [ns_window backingScaleFactor]
        objc.msgSend(layer.?, "setContentsScale:", .{scale_factor}, void); // [layer setContentsScale:scale_factor]

        break :blk gpu.Surface.Descriptor.NextInChain{ .from_metal_layer = &.{ .layer = layer.? } };
    } else unreachable;

    return instance.createSurface(&gpu.Surface.Descriptor{ .next_in_chain = extension });
}

const RequestAdapterResponse = struct {
    status: gpu.RequestAdapterStatus,
    adapter: *gpu.Adapter,
    message: ?[*:0]const u8,
};

inline fn requestAdapterCallback(
    context: *RequestAdapterResponse,
    status: gpu.RequestAdapterStatus,
    adapter: *gpu.Adapter,
    message: ?[*:0]const u8,
) void {
    context.* = RequestAdapterResponse{
        .status = status,
        .adapter = adapter,
        .message = message,
    };
}

/// Default GLFW error handling callback
fn glfwErrorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

inline fn uncapturedErrorCallback(_: void, typ: gpu.ErrorType, message: [*:0]const u8) void {
    switch (typ) {
        .validation => std.log.err("gpu: validation error: {s}\n", .{message}),
        .out_of_memory => std.log.err("gpu: out of memory: {s}\n", .{message}),
        .device_lost => std.log.err("gpu: device lost: {s}\n", .{message}),
        .unknown => std.log.err("gpu: unknown error: {s}\n", .{message}),
        else => unreachable,
    }
    std.process.exit(1);
}

fn deviceLostCallback(reason: gpu.Device.LostReason, message: [*:0]const u8, userdata: ?*anyopaque) callconv(.C) void {
    _ = userdata;
    std.log.err("device lost: {} - {s}", .{ reason, message });
}
