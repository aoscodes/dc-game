//! A simple Entity Component System, translated from Austin Morlan's C++ ECS
//! (https://austinmorlan.com/posts/entity_component_system/) into idiomatic Zig.
//!
//! Core design:
//!   - Entity  : a u32 ID
//!   - Component : a plain struct; identity is a *comptime index* in a type tuple
//!   - Signature : a bitset of component indices
//!   - World(components, systems) : the coordinator that owns all managers
//!
//! Differences from the C++ version:
//!   - No virtual dispatch / IComponentArray: comptime inline-for replaces it
//!   - No runtime type-name hashing: component/system identity is comptime index
//!   - Allocator-aware for the per-system entity bitsets

const std = @import("std");

// ---------------------------------------------------------------------------
// Primitive types
// ---------------------------------------------------------------------------

pub const Entity = u32;
pub const ComponentType = u8;

pub const MAX_ENTITIES: u32 = 5_000;
pub const MAX_COMPONENTS: u8 = 32;

/// Bitset recording which component types an entity (or system) uses.
pub const Signature = std.bit_set.IntegerBitSet(MAX_COMPONENTS);

// ---------------------------------------------------------------------------
// ComponentArray(T)  –  packed, dense array with bidirectional entity↔index map
// ---------------------------------------------------------------------------

pub fn ComponentArray(comptime T: type) type {
    return struct {
        const Self = @This();
        const INVALID: u32 = std.math.maxInt(u32);

        /// Packed storage; only data[0..size] is valid.
        data: [MAX_ENTITIES]T = undefined,
        /// entity_to_index[entity] == INVALID when not present.
        entity_to_index: [MAX_ENTITIES]u32 = [_]u32{INVALID} ** MAX_ENTITIES,
        index_to_entity: [MAX_ENTITIES]Entity = undefined,
        size: u32 = 0,

        pub fn insert(self: *Self, entity: Entity, component: T) void {
            std.debug.assert(self.entity_to_index[entity] == INVALID);
            const idx = self.size;
            self.entity_to_index[entity] = idx;
            self.index_to_entity[idx] = entity;
            self.data[idx] = component;
            self.size += 1;
        }

        /// Swap-remove: moves the last element into the vacated slot.
        pub fn remove(self: *Self, entity: Entity) void {
            const idx = self.entity_to_index[entity];
            std.debug.assert(idx != INVALID);

            const last_idx = self.size - 1;
            self.data[idx] = self.data[last_idx];

            const last_entity = self.index_to_entity[last_idx];
            self.entity_to_index[last_entity] = idx;
            self.index_to_entity[idx] = last_entity;

            self.entity_to_index[entity] = INVALID;
            self.size -= 1;
        }

        pub fn get(self: *Self, entity: Entity) *T {
            const idx = self.entity_to_index[entity];
            std.debug.assert(idx != INVALID);
            return &self.data[idx];
        }

        pub fn has(self: *const Self, entity: Entity) bool {
            return self.entity_to_index[entity] != INVALID;
        }

        pub fn on_entity_destroyed(self: *Self, entity: Entity) void {
            if (self.has(entity)) self.remove(entity);
        }
    };
}

// ---------------------------------------------------------------------------
// EntityManager  –  ID recycling queue + per-entity signatures
// ---------------------------------------------------------------------------

pub const EntityManager = struct {
    /// Simple ring buffer for recycled IDs.
    queue: [MAX_ENTITIES]Entity,
    head: u32, // read from here
    tail: u32, // write here (exclusive)
    count: u32,
    signatures: [MAX_ENTITIES]Signature,
    living_count: u32,

    pub fn init() EntityManager {
        var em = EntityManager{
            .queue = undefined,
            .head = 0,
            .tail = 0,
            .count = 0,
            .signatures = [_]Signature{Signature.initEmpty()} ** MAX_ENTITIES,
            .living_count = 0,
        };
        var i: Entity = 0;
        while (i < MAX_ENTITIES) : (i += 1) {
            em.queue[em.tail] = i;
            em.tail = (em.tail + 1) % MAX_ENTITIES;
            em.count += 1;
        }
        return em;
    }

    pub fn create(self: *EntityManager) Entity {
        std.debug.assert(self.living_count < MAX_ENTITIES);
        const id = self.queue[self.head];
        self.head = (self.head + 1) % MAX_ENTITIES;
        self.count -= 1;
        self.living_count += 1;
        return id;
    }

    pub fn destroy(self: *EntityManager, entity: Entity) void {
        std.debug.assert(entity < MAX_ENTITIES);
        self.signatures[entity] = Signature.initEmpty();
        self.queue[self.tail] = entity;
        self.tail = (self.tail + 1) % MAX_ENTITIES;
        self.count += 1;
        self.living_count -= 1;
    }

    pub fn set_signature(self: *EntityManager, entity: Entity, sig: Signature) void {
        self.signatures[entity] = sig;
    }

    pub fn get_signature(self: *const EntityManager, entity: Entity) Signature {
        return self.signatures[entity];
    }
};

// ---------------------------------------------------------------------------
// World(components, systems)  –  the Coordinator
// ---------------------------------------------------------------------------
//
//  `components` and `systems` are anonymous struct literals whose fields are
//  the concrete types to register.  Example:
//
//      const W = World(.{ Transform, Velocity }, .{ PhysicsSystem });
//
//  Each component type's bit index is its position in the `components` tuple.
//  Systems and their entity sets are stored by value inside the World struct.

pub fn World(
    comptime components: anytype,
    comptime systems: anytype,
) type {
    const CompsInfo = @typeInfo(@TypeOf(components)).@"struct";
    const SysInfo = @typeInfo(@TypeOf(systems)).@"struct";
    const n_comps = CompsInfo.fields.len;
    const n_sys = SysInfo.fields.len;

    comptime std.debug.assert(n_comps <= MAX_COMPONENTS);

    // Build a struct type with one ComponentArray(T) field per component.
    const ComponentsTuple = blk: {
        var fields: [n_comps]std.builtin.Type.StructField = undefined;
        for (CompsInfo.fields, 0..) |f, i| {
            const CT = ComponentArray(@field(components, f.name));
            fields[i] = .{
                .name = f.name,
                .type = CT,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(CT),
            };
        }
        break :blk @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    };

    // Build a struct type with one system field per system type.
    const SystemsStorage = blk: {
        var fields: [n_sys]std.builtin.Type.StructField = undefined;
        for (SysInfo.fields, 0..) |f, i| {
            const ST = @field(systems, f.name);
            fields[i] = .{
                .name = f.name,
                .type = ST,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(ST),
            };
        }
        break :blk @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    };

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        entity_manager: EntityManager,
        component_arrays: ComponentsTuple,
        systems: SystemsStorage,
        system_signatures: [n_sys]Signature,
        /// Per-system bitset of tracked entities (dynamic, MAX_ENTITIES bits each).
        system_entity_sets: [n_sys]std.bit_set.DynamicBitSet,

        // ------------------------------------------------------------------
        // Init / deinit
        // ------------------------------------------------------------------

        pub fn init(allocator: std.mem.Allocator) !Self {
            var sets: [n_sys]std.bit_set.DynamicBitSet = undefined;
            for (&sets) |*s| {
                s.* = try std.bit_set.DynamicBitSet.initEmpty(allocator, MAX_ENTITIES);
            }

            var comp_arrays: ComponentsTuple = undefined;
            inline for (@typeInfo(ComponentsTuple).@"struct".fields) |f| {
                @field(comp_arrays, f.name) = .{};
            }

            var sys_storage: SystemsStorage = undefined;
            inline for (@typeInfo(SystemsStorage).@"struct".fields) |f| {
                @field(sys_storage, f.name) = .{};
            }

            return Self{
                .allocator = allocator,
                .entity_manager = EntityManager.init(),
                .component_arrays = comp_arrays,
                .systems = sys_storage,
                .system_signatures = [_]Signature{Signature.initEmpty()} ** n_sys,
                .system_entity_sets = sets,
            };
        }

        pub fn deinit(self: *Self) void {
            for (&self.system_entity_sets) |*s| s.deinit();
        }

        // ------------------------------------------------------------------
        // Component type index (comptime)
        // ------------------------------------------------------------------

        /// Compile-time: bit position for component type C.
        pub fn component_type(comptime C: type) ComponentType {
            inline for (CompsInfo.fields, 0..) |f, i| {
                if (@field(components, f.name) == C) return @intCast(i);
            }
            @compileError("Component not in World: " ++ @typeName(C));
        }

        // ------------------------------------------------------------------
        // System signature
        // ------------------------------------------------------------------

        pub fn set_system_signature(self: *Self, comptime S: type, sig: Signature) void {
            self.system_signatures[comptime system_index(S)] = sig;
        }

        // ------------------------------------------------------------------
        // Entity lifecycle
        // ------------------------------------------------------------------

        pub fn create_entity(self: *Self) Entity {
            return self.entity_manager.create();
        }

        pub fn destroy_entity(self: *Self, entity: Entity) void {
            self.entity_manager.destroy(entity);
            inline for (@typeInfo(ComponentsTuple).@"struct".fields) |f| {
                @field(self.component_arrays, f.name).on_entity_destroyed(entity);
            }
            for (&self.system_entity_sets) |*set| set.unset(entity);
        }

        // ------------------------------------------------------------------
        // Component add / remove / get
        // ------------------------------------------------------------------

        pub fn add_component(self: *Self, entity: Entity, component: anytype) void {
            const C = @TypeOf(component);
            @field(self.component_arrays, comp_field(C)).insert(entity, component);

            var sig = self.entity_manager.get_signature(entity);
            sig.set(component_type(C));
            self.entity_manager.set_signature(entity, sig);
            self.refresh_systems(entity, sig);
        }

        pub fn remove_component(self: *Self, entity: Entity, comptime C: type) void {
            @field(self.component_arrays, comp_field(C)).remove(entity);

            var sig = self.entity_manager.get_signature(entity);
            sig.unset(component_type(C));
            self.entity_manager.set_signature(entity, sig);
            self.refresh_systems(entity, sig);
        }

        pub fn get_component(self: *Self, entity: Entity, comptime C: type) *C {
            return @field(self.component_arrays, comp_field(C)).get(entity);
        }

        // ------------------------------------------------------------------
        // System access
        // ------------------------------------------------------------------

        /// Direct pointer to a system's state struct.
        pub fn get_system(self: *Self, comptime S: type) *S {
            return &@field(self.systems, sys_field(S));
        }

        /// Call cb(world, entity, system_ptr) for each entity tracked by S.
        pub fn each(
            self: *Self,
            comptime S: type,
            comptime cb: fn (*Self, Entity, *S) void,
        ) void {
            const sys_ptr = self.get_system(S);
            var iter = self.system_entity_sets[comptime system_index(S)].iterator(.{});
            while (iter.next()) |usize_entity| cb(self, @intCast(usize_entity), sys_ptr);
        }

        // ------------------------------------------------------------------
        // Internal helpers
        // ------------------------------------------------------------------

        fn refresh_systems(self: *Self, entity: Entity, entity_sig: Signature) void {
            inline for (0..n_sys) |i| {
                const sys_sig = self.system_signatures[i];
                if (entity_sig.intersectWith(sys_sig).eql(sys_sig)) {
                    self.system_entity_sets[i].set(entity);
                } else {
                    self.system_entity_sets[i].unset(entity);
                }
            }
        }

        fn comp_field(comptime C: type) []const u8 {
            inline for (CompsInfo.fields) |f| {
                if (@field(components, f.name) == C) return f.name;
            }
            @compileError("Component not in World: " ++ @typeName(C));
        }

        fn sys_field(comptime S: type) []const u8 {
            inline for (SysInfo.fields) |f| {
                if (@field(systems, f.name) == S) return f.name;
            }
            @compileError("System not in World: " ++ @typeName(S));
        }

        fn system_index(comptime S: type) usize {
            inline for (SysInfo.fields, 0..) |f, i| {
                if (@field(systems, f.name) == S) return i;
            }
            @compileError("System not in World: " ++ @typeName(S));
        }
    };
}
