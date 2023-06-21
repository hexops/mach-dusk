const ChainedStruct = @import("gpu.zig").ChainedStruct;
const BindGroupLayout = @import("bind_group_layout.zig").BindGroupLayout;
const Impl = @import("interface.zig").Impl;

pub const PipelineLayout = opaque {
    pub const Descriptor = extern struct {
        next_in_chain: ?*const ChainedStruct = null,
        label: ?[*:0]const u8 = null,
        bind_group_layout_count: u32 = 0,
        bind_group_layouts: ?[*]const *BindGroupLayout = null,

        /// Provides a slightly friendlier Zig API to initialize this structure.
        pub inline fn init(v: struct {
            next_in_chain: ?*const ChainedStruct = null,
            label: ?[*:0]const u8 = null,
            bind_group_layouts: ?[]const *BindGroupLayout = null,
        }) Descriptor {
            return .{
                .next_in_chain = v.next_in_chain,
                .label = v.label,
                .bind_group_layout_count = if (v.bind_group_layouts) |e| @intCast(u32, e.len) else 0,
                .bind_group_layouts = if (v.bind_group_layouts) |e| e.ptr else null,
            };
        }
    };
};