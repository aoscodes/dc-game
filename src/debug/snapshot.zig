//! Binary ECS world snapshot: write and read back all component data.
//!
//! Format (little-endian):
//!
//!   [4]  magic      "ECSS"
//!   [4]  n_comps    u32  — number of component arrays that follow
//!   per component:
//!     [32] name     [32]u8  (null-padded)
//!     [4]  elem_sz  u32     — sizeof(T) for this array's element type
//!     [4]  count    u32     — number of live entries
//!     [count * elem_sz]    component values (packed, native layout)
//!     [count * 4]          entity IDs (u32 little-endian each)
//!   [4]  living_count  u32  — number of living entities
//!   [living_count * 4]     living entity IDs (u32 little-endian each)
//!
//! Reading reconstructs the world by calling `world.add_component` for
//! each recorded (entity, component) pair in order.  The reader expects
//! a freshly-init world with no existing entities.
//!
//! Usage:
//!
//!   // write
//!   var file = try std.fs.cwd().createFile("snap.bin", .{});
//!   defer file.close();
//!   try Snapshot(GameWorld).write(&world, file.writer(), living.items);
//!
//!   // read
//!   var world2 = try GameWorld.init(allocator);
//!   var file2 = try std.fs.cwd().openFile("snap.bin", .{});
//!   defer file2.close();
//!   try Snapshot(GameWorld).read(&world2, file2.reader());

const std = @import("std");
const ecs = @import("ecs_zig");

const MAGIC = "ECSS";
const NAME_LEN = 32;

/// Returns a namespace with `write` and `read` specialised for world type W.
pub fn Snapshot(comptime W: type) type {
    return struct {
        /// Serialise all component arrays plus living entity list to `writer`.
        pub fn write(
            world: *W,
            writer: anytype,
            living: []const ecs.Entity,
        ) !void {
            try writer.writeAll(MAGIC);

            const comp_arrays = &world.component_arrays;
            const CT = @TypeOf(comp_arrays.*);
            const fields = @typeInfo(CT).@"struct".fields;
            const n_comps: u32 = @intCast(fields.len);
            try writer.writeInt(u32, n_comps, .little);

            inline for (fields) |f| {
                const arr = &@field(comp_arrays, f.name);
                const T = @TypeOf(arr.data[0]);
                const elem_sz: u32 = @sizeOf(T);
                const count: u32 = arr.size;

                // name (null-padded to NAME_LEN)
                var name_buf = [_]u8{0} ** NAME_LEN;
                const copy_len = @min(f.name.len, NAME_LEN);
                @memcpy(name_buf[0..copy_len], f.name[0..copy_len]);
                try writer.writeAll(&name_buf);

                try writer.writeInt(u32, elem_sz, .little);
                try writer.writeInt(u32, count, .little);

                // component values
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    try writer.writeAll(std.mem.asBytes(&arr.data[i]));
                }
                // entity IDs
                i = 0;
                while (i < count) : (i += 1) {
                    try writer.writeInt(u32, arr.index_to_entity[i], .little);
                }
            }

            // living entity list
            try writer.writeInt(u32, @intCast(living.len), .little);
            for (living) |e| try writer.writeInt(u32, e, .little);
        }

        /// Deserialise into a freshly-init world.  Returns error on magic/size
        /// mismatch or unexpected EOF.
        pub fn read(world: *W, reader: anytype) !void {
            var magic: [4]u8 = undefined;
            _ = try reader.readAll(&magic);
            if (!std.mem.eql(u8, &magic, MAGIC)) return error.BadMagic;

            const n_comps = try reader.readInt(u32, .little);

            const comp_arrays = &world.component_arrays;
            const CT = @TypeOf(comp_arrays.*);
            const fields = @typeInfo(CT).@"struct".fields;

            // We read exactly n_comps blocks; match by name to field.
            var c: u32 = 0;
            while (c < n_comps) : (c += 1) {
                var name_buf: [NAME_LEN]u8 = undefined;
                _ = try reader.readAll(&name_buf);
                const name = std.mem.sliceTo(&name_buf, 0);

                const elem_sz = try reader.readInt(u32, .little);
                const count = try reader.readInt(u32, .little);

                // Find the matching field; if unknown, skip payload.
                var matched = false;
                inline for (fields) |f| {
                    if (std.mem.eql(u8, f.name, name)) {
                        const arr = &@field(comp_arrays, f.name);
                        const T = @TypeOf(arr.data[0]);
                        if (@sizeOf(T) != elem_sz) return error.SizeMismatch;
                        matched = true;
                        // Read component values into a temp buffer, then entities
                        var vals: [ecs.MAX_ENTITIES]T = undefined;
                        var i: u32 = 0;
                        while (i < count) : (i += 1) {
                            var raw: [@sizeOf(T)]u8 = undefined;
                            _ = try reader.readAll(&raw);
                            vals[i] = std.mem.bytesToValue(T, &raw);
                        }
                        var entities: [ecs.MAX_ENTITIES]ecs.Entity = undefined;
                        i = 0;
                        while (i < count) : (i += 1) {
                            entities[i] = try reader.readInt(u32, .little);
                        }
                        // Reconstruct: create entities if needed, add components
                        i = 0;
                        while (i < count) : (i += 1) {
                            const e = entities[i];
                            // Only insert if not already present (another
                            // component may have created this entity already).
                            if (!arr.has(e)) {
                                arr.insert(e, vals[i]);
                                // Ensure the entity has a valid (non-empty)
                                // signature so destroy_entity works later.
                                var sig = world.entity_manager.get_signature(e);
                                sig.set(W.component_type(T));
                                world.entity_manager.set_signature(e, sig);
                            }
                        }
                    }
                }
                if (!matched) {
                    // Unknown component: skip payload bytes
                    const skip = count * (elem_sz + @sizeOf(u32));
                    var j: u32 = 0;
                    while (j < skip) : (j += 1) _ = try reader.readByte();
                }
            }

            // Restore living_count in EntityManager
            const living_count = try reader.readInt(u32, .little);
            world.entity_manager.living_count = living_count;
        }
    };
}
