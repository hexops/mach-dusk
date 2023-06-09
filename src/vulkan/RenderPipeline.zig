const std = @import("std");
const vk = @import("vulkan");
const gpu = @import("gpu");
const Device = @import("Device.zig");
const ShaderModule = @import("ShaderModule.zig");
const PipelineLayout = @import("PipelineLayout.zig");
const global = @import("global.zig");
const Manager = @import("../helper.zig").Manager;

const RenderPipeline = @This();

manager: Manager(RenderPipeline) = .{},
device: *Device,
pipeline: vk.Pipeline,
render_pass_raw: vk.RenderPass,

pub fn init(device: *Device, desc: *const gpu.RenderPipeline.Descriptor) !RenderPipeline {
    // Create shader stages
    var stages: [2]vk.PipelineShaderStageCreateInfo = undefined;
    var stage_count: u32 = 1;

    const vertex_shader: *ShaderModule = @ptrCast(@alignCast(desc.vertex.module));
    stages[0] = .{
        .stage = .{ .vertex_bit = true },
        .module = vertex_shader.shader_module,
        .p_name = desc.vertex.entry_point,
        .p_specialization_info = null,
    };

    if (desc.fragment) |frag| {
        stage_count += 1;
        const frag_shader: *ShaderModule = @ptrCast(@alignCast(frag.module));
        stages[1] = .{
            .stage = .{ .fragment_bit = true },
            .module = frag_shader.shader_module,
            .p_name = frag.entry_point,
            .p_specialization_info = null,
        };
    }

    // Configure vertex stage
    const vertex_bindings = try device.allocator.alloc(vk.VertexInputBindingDescription, desc.vertex.buffer_count);
    defer device.allocator.free(vertex_bindings);
    var vertex_attrs = std.ArrayList(vk.VertexInputAttributeDescription).init(device.allocator);
    defer vertex_attrs.deinit();
    for (vertex_bindings, 0..) |*binding, i| {
        const buf = desc.vertex.buffers.?[i];
        binding.* = .{
            .binding = @intCast(i),
            .stride = @intCast(buf.array_stride),
            .input_rate = switch (buf.step_mode) {
                .vertex => .vertex,
                .instance => .instance,
                .vertex_buffer_not_used => unreachable,
            },
        };

        for (buf.attributes.?[0..buf.attribute_count]) |attr| {
            try vertex_attrs.append(.{
                .location = attr.shader_location,
                .binding = @intCast(i),
                .format = global.vulkanFormatFromVertexFormat(attr.format),
                .offset = @intCast(attr.offset),
            });
        }
    }

    const vertex_input = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = @intCast(vertex_bindings.len),
        .p_vertex_binding_descriptions = vertex_bindings.ptr,
        .vertex_attribute_description_count = @intCast(vertex_attrs.items.len),
        .p_vertex_attribute_descriptions = vertex_attrs.items.ptr,
    };

    var layout = if (desc.layout) |layout|
        @as(*PipelineLayout, @ptrCast(@alignCast(layout))).*
    else
        try PipelineLayout.init(device, &.{});
    defer layout.deinit();

    // Configure fragment stage
    // TODO: how to free?
    var color_attachments: []vk.PipelineColorBlendAttachmentState = &.{};
    var attachments: []vk.AttachmentDescription = &.{};
    var attachment_refs: []vk.AttachmentReference = &.{};
    if (desc.fragment) |frag| {
        color_attachments = try device.allocator.alloc(vk.PipelineColorBlendAttachmentState, frag.target_count);
        attachments = try device.allocator.alloc(vk.AttachmentDescription, frag.target_count);
        attachment_refs = try device.allocator.alloc(vk.AttachmentReference, frag.target_count);

        for (color_attachments, attachments, attachment_refs, 0..) |*color_attachment, *attachment, *attachment_ref, i| {
            const target = frag.targets.?[i];
            const blend = target.blend orelse &gpu.BlendState{};
            color_attachment.* = .{
                .blend_enable = vk.FALSE,
                .src_color_blend_factor = getBlendFactor(blend.color.src_factor),
                .dst_color_blend_factor = getBlendFactor(blend.color.dst_factor),
                .color_blend_op = getBlendOp(blend.color.operation),
                .src_alpha_blend_factor = getBlendFactor(blend.alpha.src_factor),
                .dst_alpha_blend_factor = getBlendFactor(blend.alpha.dst_factor),
                .alpha_blend_op = getBlendOp(blend.alpha.operation),
                .color_write_mask = .{
                    .r_bit = target.write_mask.red,
                    .g_bit = target.write_mask.green,
                    .b_bit = target.write_mask.blue,
                    .a_bit = target.write_mask.alpha,
                },
            };
            attachment.* = .{
                .format = global.vulkanFormatFromTextureFormat(target.format),
                .samples = getSampleCountFlags(desc.multisample.count),
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .clear,
                .stencil_store_op = .store,
                .initial_layout = .depth_stencil_read_only_optimal,
                .final_layout = .depth_stencil_attachment_optimal,
            };
            attachment_ref.* = .{
                .attachment = @intCast(i),
                .layout = .general,
            };
        }
    }

    const rasterization = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{
            .front_bit = desc.primitive.cull_mode == .front,
            .back_bit = desc.primitive.cull_mode == .back,
        },
        .front_face = switch (desc.primitive.front_face) {
            .ccw => vk.FrontFace.counter_clockwise,
            .cw => vk.FrontFace.clockwise,
        },
        .depth_bias_enable = isDepthBiasEnabled(desc.depth_stencil),
        .depth_bias_constant_factor = getDepthBias(desc.depth_stencil),
        .depth_bias_clamp = getDepthBiasClamp(desc.depth_stencil),
        .depth_bias_slope_factor = getDepthBiasSlopeScale(desc.depth_stencil),
        .line_width = 1,
    };
    const multisample = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = getSampleCountFlags(desc.multisample.count),
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 0,
        .p_sample_mask = &[_]u32{desc.multisample.mask},
        .alpha_to_coverage_enable = @intFromBool(desc.multisample.alpha_to_coverage_enabled),
        .alpha_to_one_enable = vk.FALSE,
    };
    const depth_stencil: vk.PipelineDepthStencilStateCreateInfo = if (desc.depth_stencil) |ds| .{
        .depth_test_enable = @intFromBool(ds.depth_compare == .always and ds.depth_write_enabled),
        .depth_write_enable = @intFromBool(ds.depth_write_enabled),
        .depth_compare_op = getCompareOp(ds.depth_compare),
        .depth_bounds_test_enable = vk.FALSE,
        .stencil_test_enable = @intFromBool(ds.stencil_read_mask != 0 or ds.stencil_write_mask != 0),
        .front = .{
            .fail_op = getStencilOp(ds.stencil_front.fail_op),
            .depth_fail_op = getStencilOp(ds.stencil_front.depth_fail_op),
            .pass_op = getStencilOp(ds.stencil_front.pass_op),
            .compare_op = getCompareOp(ds.stencil_front.compare),
            .compare_mask = ds.stencil_read_mask,
            .write_mask = ds.stencil_write_mask,
            .reference = 0,
        },
        .back = .{
            .fail_op = getStencilOp(ds.stencil_back.fail_op),
            .depth_fail_op = getStencilOp(ds.stencil_back.depth_fail_op),
            .pass_op = getStencilOp(ds.stencil_back.pass_op),
            .compare_op = getCompareOp(ds.stencil_back.compare),
            .compare_mask = ds.stencil_read_mask,
            .write_mask = ds.stencil_write_mask,
            .reference = 0,
        },
        .min_depth_bounds = 0,
        .max_depth_bounds = 1,
    } else .{
        .depth_test_enable = vk.FALSE,
        .depth_write_enable = vk.FALSE,
        .depth_compare_op = .never,
        .depth_bounds_test_enable = vk.FALSE,
        .stencil_test_enable = vk.FALSE,
        .front = .{
            .fail_op = .keep,
            .depth_fail_op = .keep,
            .pass_op = .keep,
            .compare_op = .never,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .back = .{
            .fail_op = .keep,
            .depth_fail_op = .keep,
            .pass_op = .keep,
            .compare_op = .never,
            .compare_mask = 0,
            .write_mask = 0,
            .reference = 0,
        },
        .min_depth_bounds = 0,
        .max_depth_bounds = 1,
    };
    const color_blend = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .clear,
        .attachment_count = @intCast(color_attachments.len),
        .p_attachments = color_attachments.ptr,
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = switch (desc.primitive.topology) {
            .point_list => .point_list,
            .line_list => .line_list,
            .line_strip => .line_strip,
            .triangle_list => .triangle_list,
            .triangle_strip => .triangle_strip,
        },
        .primitive_restart_enable = @intFromBool(desc.primitive.strip_index_format != .undefined),
    };
    const viewport = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .scissor_count = 1,
    };
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor, .stencil_reference, .blend_constants };
    const dynamic = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    const render_pass_raw = try device.dispatch.createRenderPass(device.device, &vk.RenderPassCreateInfo{
        .attachment_count = @intCast(attachments.len),
        .p_attachments = attachments.ptr,
        .subpass_count = 1,
        .p_subpasses = &[_]vk.SubpassDescription{.{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = @intCast(attachment_refs.len),
            .p_color_attachments = attachment_refs.ptr,
        }},
    }, null);

    var pipeline: vk.Pipeline = undefined;
    _ = try device.dispatch.createGraphicsPipelines(device.device, .null_handle, 1, &[_]vk.GraphicsPipelineCreateInfo{.{
        .stage_count = stage_count,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport,
        .p_rasterization_state = &rasterization,
        .p_multisample_state = &multisample,
        .p_depth_stencil_state = &depth_stencil,
        .p_color_blend_state = &color_blend,
        .p_dynamic_state = &dynamic,
        .layout = layout.layout,
        .render_pass = render_pass_raw,
        .subpass = 0,
        .base_pipeline_index = -1,
    }}, null, @ptrCast(&pipeline));

    return .{
        .device = device,
        .pipeline = pipeline,
        .render_pass_raw = render_pass_raw,
    };
}

pub fn deinit(render_pipeline: *RenderPipeline) void {
    render_pipeline.device.dispatch.destroyRenderPass(render_pipeline.device.device, render_pipeline.render_pass_raw, null);
    render_pipeline.device.dispatch.destroyPipeline(render_pipeline.device.device, render_pipeline.pipeline, null);
}

fn isDepthBiasEnabled(ds: ?*const gpu.DepthStencilState) vk.Bool32 {
    if (ds == null) return vk.FALSE;
    return @intFromBool(ds.?.depth_bias != 0 or ds.?.depth_bias_slope_scale != 0);
}

fn getDepthBias(ds: ?*const gpu.DepthStencilState) f32 {
    if (ds == null) return 0;
    return @floatFromInt(ds.?.depth_bias);
}

fn getDepthBiasClamp(ds: ?*const gpu.DepthStencilState) f32 {
    if (ds == null) return 0;
    return ds.?.depth_bias_clamp;
}

fn getDepthBiasSlopeScale(ds: ?*const gpu.DepthStencilState) f32 {
    if (ds == null) return 0;
    return ds.?.depth_bias_slope_scale;
}

pub fn getSampleCountFlags(samples: u32) vk.SampleCountFlags {
    // TODO: https://github.com/Snektron/vulkan-zig/issues/27
    return switch (samples) {
        1 => .{ .@"1_bit" = true },
        2 => .{ .@"2_bit" = true },
        4 => .{ .@"4_bit" = true },
        8 => .{ .@"8_bit" = true },
        16 => .{ .@"16_bit" = true },
        32 => .{ .@"32_bit" = true },
        else => unreachable,
    };
}

pub fn getCompareOp(op: gpu.CompareFunction) vk.CompareOp {
    return switch (op) {
        .never => .never,
        .less => .less,
        .less_equal => .less_or_equal,
        .greater => .greater,
        .greater_equal => .greater_or_equal,
        .equal => .equal,
        .not_equal => .not_equal,
        .always => .always,
        .undefined => unreachable,
    };
}

pub fn getStencilOp(op: gpu.StencilOperation) vk.StencilOp {
    return switch (op) {
        .keep => .keep,
        .zero => .zero,
        .replace => .replace,
        .invert => .invert,
        .increment_clamp => .increment_and_clamp,
        .decrement_clamp => .decrement_and_clamp,
        .increment_wrap => .increment_and_wrap,
        .decrement_wrap => .decrement_and_wrap,
    };
}

pub fn getBlendOp(op: gpu.BlendOperation) vk.BlendOp {
    return switch (op) {
        .add => .add,
        .subtract => .subtract,
        .reverse_subtract => .reverse_subtract,
        .min => .min,
        .max => .max,
    };
}

pub fn getBlendFactor(op: gpu.BlendFactor) vk.BlendFactor {
    return switch (op) {
        .zero => .zero,
        .one => .one,
        .src => .src_color,
        .one_minus_src => .one_minus_src_color,
        .src_alpha => .src_alpha,
        .one_minus_src_alpha => .one_minus_src_alpha,
        .dst => .dst_color,
        .one_minus_dst => .one_minus_dst_color,
        .dst_alpha => .dst_alpha,
        .one_minus_dst_alpha => .one_minus_dst_alpha,
        .src_alpha_saturated => .src_alpha_saturate,
        .constant => .constant_color,
        .one_minus_constant => .one_minus_constant_color,
    };
}
