//! Binary wire protocol for client↔server communication.
//!
//! Every message is a packed byte stream:
//!   [1 byte MsgTag] [payload bytes...]
//!
//! All multi-byte integers are little-endian.
//! Strings are length-prefixed: [u8 len][bytes...] (max 255 bytes).
//!
//! Encoding/decoding uses std.io Reader/Writer passed by the caller; no
//! internal allocation.  The caller owns all buffers.
//!
//! Design rule: every field has a fixed or length-prefixed size.  No
//! optional fields inside a message — use a separate MsgTag variant instead.

const std = @import("std");
const components = @import("components.zig");

pub const MsgTag = enum(u8) {
    join_lobby = 0x01,
    choose_class = 0x02,
    ready_up = 0x03,
    choose_action = 0x04,
    reconnect = 0x05,
    choose_position = 0x06, // cosmetic lobby position only

    lobby_update = 0x10,
    game_start = 0x11,
    game_state = 0x12,
    action_result = 0x13,
    game_over = 0x15,
    @"error" = 0x1F,
};

pub const JoinLobby = struct {
    name: [16]u8,
    name_len: u8,
};

pub const ChooseClass = struct {
    class: components.ClassTag,
};

pub const ChoosePosition = struct {
    col: u8,
    row: u8,
};

pub const ChooseAction = struct {
    action: components.ActionChoice,
};

pub const Reconnect = struct {
    player_id: u8,
};

pub const MAX_PLAYERS: u8 = 6;

pub const PlayerInfo = struct {
    player_id: u8,
    name: [16]u8,
    name_len: u8,
    class: components.ClassTag,
    ready: bool,
    connected: bool,
    /// Cosmetic lobby grid position (col 0–2, row 0–3). No gameplay effect.
    grid_col: u8,
    grid_row: u8,
};

pub const LobbyUpdate = struct {
    join_code: [6]u8,
    player_count: u8,
    players: [MAX_PLAYERS]PlayerInfo,
    player_id: u8,
    /// Proposed round duration (seconds). Displayed in lobby; sent at game start.
    round_duration: f32,
};

pub const GameStart = struct {
    wave_label: [32]u8,
    wave_label_len: u8,
    player_id: u8,
    round_duration: f32,
};

pub const EntitySnapshot = struct {
    entity: u32,
    /// Cosmetic slot index (0-based spawn order). No gameplay meaning.
    slot: u8,
    hp_current: u16,
    hp_max: u16,
    shield_hp: u16,
    class: components.ClassTag,
    team: components.TeamId,
    owner: u8,
};

pub const MAX_ENTITIES_WIRE: u16 = 64;

pub const GameState = struct {
    tick: u32,
    /// Seconds remaining in the current round.
    round_timer: f32,
    entity_count: u8,
    entities: [MAX_ENTITIES_WIRE]EntitySnapshot,
};

pub const ActionResultTag = enum(u8) {
    damage = 0,
    heal = 1,
    shield = 2,
    death = 4,
};

pub const ActionResult = struct {
    tag: ActionResultTag,
    /// 0xFFFFFFFF = no specific actor (pool action).
    actor_entity: u32,
    target_entity: u32,
    value: u16,
};

pub const WinnerId = enum(u8) {
    players = 0,
    enemies = 1,
};

pub const GameOver = struct {
    winner: WinnerId,
};

pub const Error = struct {
    message: [64]u8,
};

pub fn encode(writer: anytype, comptime tag: MsgTag, payload: anytype) !void {
    try writer.writeByte(@intFromEnum(tag));
    const T = @TypeOf(payload);

    if (T == void) return;

    switch (tag) {
        .join_lobby => try encode_join_lobby(writer, payload),
        .choose_class => try writer.writeByte(@intFromEnum(payload.class)),
        .ready_up => {},
        .choose_action => try writer.writeByte(@intFromEnum(payload.action)),
        .reconnect => try writer.writeByte(payload.player_id),
        .choose_position => {
            try writer.writeByte(payload.col);
            try writer.writeByte(payload.row);
        },

        .lobby_update => try encode_lobby_update(writer, payload),
        .game_start => try encode_game_start(writer, payload),
        .game_state => try encode_game_state(writer, payload),
        .action_result => try encode_action_result(writer, payload),
        .game_over => try writer.writeByte(@intFromEnum(payload.winner)),
        .@"error" => try writer.writeAll(&payload.message),
    }
}

fn encode_join_lobby(w: anytype, p: JoinLobby) !void {
    try w.writeByte(p.name_len);
    try w.writeAll(p.name[0..p.name_len]);
}

fn encode_lobby_update(w: anytype, p: LobbyUpdate) !void {
    try w.writeAll(&p.join_code);
    try w.writeByte(p.player_count);
    try w.writeByte(p.player_id);
    try w.writeAll(std.mem.asBytes(&p.round_duration));
    var i: u8 = 0;
    while (i < p.player_count) : (i += 1) {
        const pl = p.players[i];
        try w.writeByte(pl.player_id);
        try w.writeByte(pl.name_len);
        try w.writeAll(pl.name[0..pl.name_len]);
        try w.writeByte(@intFromEnum(pl.class));
        try w.writeByte(if (pl.ready) 1 else 0);
        try w.writeByte(if (pl.connected) 1 else 0);
        try w.writeByte(pl.grid_col);
        try w.writeByte(pl.grid_row);
    }
}

fn encode_game_start(w: anytype, p: GameStart) !void {
    try w.writeByte(p.wave_label_len);
    try w.writeAll(p.wave_label[0..p.wave_label_len]);
    try w.writeByte(p.player_id);
    try w.writeAll(std.mem.asBytes(&p.round_duration));
}

fn encode_game_state(w: anytype, p: GameState) !void {
    try w.writeInt(u32, p.tick, .little);
    try w.writeAll(std.mem.asBytes(&p.round_timer));
    try w.writeByte(p.entity_count);
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        const e = p.entities[i];
        try w.writeInt(u32, e.entity, .little);
        try w.writeByte(e.slot);
        try w.writeInt(u16, e.hp_current, .little);
        try w.writeInt(u16, e.hp_max, .little);
        try w.writeInt(u16, e.shield_hp, .little);
        try w.writeByte(@intFromEnum(e.class));
        try w.writeByte(@intFromEnum(e.team));
        try w.writeByte(e.owner);
    }
}

fn encode_action_result(w: anytype, p: ActionResult) !void {
    try w.writeByte(@intFromEnum(p.tag));
    try w.writeInt(u32, p.actor_entity, .little);
    try w.writeInt(u32, p.target_entity, .little);
    try w.writeInt(u16, p.value, .little);
}

pub const DecodeError = error{
    UnknownTag,
    InvalidClass,
    InvalidActionChoice,
    InvalidTeam,
    InvalidActionResultTag,
    InvalidWinner,
    NameTooLong,
    TooManyEntities,
};

pub fn read_tag(reader: anytype) !MsgTag {
    const byte = try reader.readByte();
    return std.meta.intToEnum(MsgTag, byte) catch return DecodeError.UnknownTag;
}

pub fn decode_join_lobby(reader: anytype) !JoinLobby {
    const len = try reader.readByte();
    if (len == 0 or len > 16) return DecodeError.NameTooLong;
    var p = JoinLobby{ .name = [_]u8{0} ** 16, .name_len = len };
    _ = try reader.readAll(p.name[0..len]);
    return p;
}

pub fn decode_choose_class(reader: anytype) !ChooseClass {
    const byte = try reader.readByte();
    const class = std.meta.intToEnum(components.ClassTag, byte) catch
        return DecodeError.InvalidClass;
    return .{ .class = class };
}

pub fn decode_choose_action(reader: anytype) !ChooseAction {
    const byte = try reader.readByte();
    const action = std.meta.intToEnum(components.ActionChoice, byte) catch
        return DecodeError.InvalidActionChoice;
    return .{ .action = action };
}

pub fn decode_reconnect(reader: anytype) !Reconnect {
    return .{ .player_id = try reader.readByte() };
}

pub fn decode_choose_position(reader: anytype) !ChoosePosition {
    return .{ .col = try reader.readByte(), .row = try reader.readByte() };
}

pub fn decode_lobby_update(reader: anytype) !LobbyUpdate {
    var p: LobbyUpdate = undefined;
    _ = try reader.readAll(&p.join_code);
    p.player_count = try reader.readByte();
    p.player_id = try reader.readByte();
    if (p.player_count > MAX_PLAYERS) return DecodeError.TooManyEntities;
    var rd_bytes: [4]u8 = undefined;
    _ = try reader.readAll(&rd_bytes);
    p.round_duration = std.mem.bytesToValue(f32, &rd_bytes);
    var i: u8 = 0;
    while (i < p.player_count) : (i += 1) {
        p.players[i].player_id = try reader.readByte();
        const nlen = try reader.readByte();
        if (nlen > 16) return DecodeError.NameTooLong;
        p.players[i].name = [_]u8{0} ** 16;
        p.players[i].name_len = nlen;
        _ = try reader.readAll(p.players[i].name[0..nlen]);
        const class_byte = try reader.readByte();
        p.players[i].class = std.meta.intToEnum(components.ClassTag, class_byte) catch
            return DecodeError.InvalidClass;
        p.players[i].ready = (try reader.readByte()) != 0;
        p.players[i].connected = (try reader.readByte()) != 0;
        p.players[i].grid_col = try reader.readByte();
        p.players[i].grid_row = try reader.readByte();
    }
    return p;
}

pub fn decode_game_start(reader: anytype) !GameStart {
    var p: GameStart = undefined;
    const llen = try reader.readByte();
    p.wave_label = [_]u8{0} ** 32;
    p.wave_label_len = llen;
    _ = try reader.readAll(p.wave_label[0..llen]);
    p.player_id = try reader.readByte();
    var rd_bytes: [4]u8 = undefined;
    _ = try reader.readAll(&rd_bytes);
    p.round_duration = std.mem.bytesToValue(f32, &rd_bytes);
    return p;
}

pub fn decode_game_state(reader: anytype) !GameState {
    var p: GameState = undefined;
    p.tick = try reader.readInt(u32, .little);
    var rt_bytes: [4]u8 = undefined;
    _ = try reader.readAll(&rt_bytes);
    p.round_timer = std.mem.bytesToValue(f32, &rt_bytes);
    p.entity_count = try reader.readByte();
    if (p.entity_count > MAX_ENTITIES_WIRE) return DecodeError.TooManyEntities;
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        var e: EntitySnapshot = undefined;
        e.entity = try reader.readInt(u32, .little);
        e.slot = try reader.readByte();
        e.hp_current = try reader.readInt(u16, .little);
        e.hp_max = try reader.readInt(u16, .little);
        e.shield_hp = try reader.readInt(u16, .little);
        const class_byte = try reader.readByte();
        e.class = std.meta.intToEnum(components.ClassTag, class_byte) catch
            return DecodeError.InvalidClass;
        const team_byte = try reader.readByte();
        e.team = std.meta.intToEnum(components.TeamId, team_byte) catch
            return DecodeError.InvalidTeam;
        e.owner = try reader.readByte();
        p.entities[i] = e;
    }
    return p;
}

pub fn decode_action_result(reader: anytype) !ActionResult {
    const tag_byte = try reader.readByte();
    const tag = std.meta.intToEnum(ActionResultTag, tag_byte) catch
        return DecodeError.InvalidActionResultTag;
    return .{
        .tag = tag,
        .actor_entity = try reader.readInt(u32, .little),
        .target_entity = try reader.readInt(u32, .little),
        .value = try reader.readInt(u16, .little),
    };
}

pub fn decode_game_over(reader: anytype) !GameOver {
    const byte = try reader.readByte();
    const winner = std.meta.intToEnum(WinnerId, byte) catch
        return DecodeError.InvalidWinner;
    return .{ .winner = winner };
}

test "round-trip: choose_action damage" {
    var buf: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const msg = ChooseAction{ .action = .damage };
    try encode(fbs.writer(), .choose_action, msg);

    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.choose_action, tag);
    const decoded = try decode_choose_action(fbs.reader());
    try std.testing.expectEqual(msg.action, decoded.action);
}

test "round-trip: game_over" {
    var buf: [8]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try encode(fbs.writer(), .game_over, GameOver{ .winner = .players });
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.game_over, tag);
    const decoded = try decode_game_over(fbs.reader());
    try std.testing.expectEqual(WinnerId.players, decoded.winner);
}

test "round-trip: join_lobby" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const name = "Alice";
    var p = JoinLobby{ .name = [_]u8{0} ** 16, .name_len = @intCast(name.len) };
    @memcpy(p.name[0..name.len], name);

    try encode(fbs.writer(), .join_lobby, p);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_join_lobby(fbs.reader());
    try std.testing.expectEqual(p.name_len, decoded.name_len);
    try std.testing.expectEqualSlices(u8, name, decoded.name[0..decoded.name_len]);
}

test "round-trip: game_state — round_timer and shield_hp survive" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState{
        .tick = 42,
        .round_timer = 1.75,
        .entity_count = 1,
        .entities = [_]EntitySnapshot{std.mem.zeroes(EntitySnapshot)} ** MAX_ENTITIES_WIRE,
    };
    gs.entities[0] = EntitySnapshot{
        .entity = 7,
        .slot = 0,
        .hp_current = 80,
        .hp_max = 100,
        .shield_hp = 5,
        .class = .fighter,
        .team = .players,
        .owner = 0,
    };

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.game_state, tag);
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u32, 42), decoded.tick);
    try std.testing.expectApproxEqAbs(@as(f32, 1.75), decoded.round_timer, 0.001);
    try std.testing.expectEqual(@as(u8, 1), decoded.entity_count);
    try std.testing.expectEqual(@as(u16, 5), decoded.entities[0].shield_hp);
    try std.testing.expectEqual(@as(u16, 80), decoded.entities[0].hp_current);
}

test "round-trip: lobby_update — round_duration survives" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var lu = LobbyUpdate{
        .join_code = "ABCDEF".*,
        .player_count = 1,
        .players = [_]PlayerInfo{std.mem.zeroes(PlayerInfo)} ** MAX_PLAYERS,
        .player_id = 0,
        .round_duration = 2.5,
    };
    lu.players[0] = PlayerInfo{
        .player_id = 0,
        .name = [_]u8{0} ** 16,
        .name_len = 3,
        .class = .fighter,
        .ready = false,
        .connected = true,
        .grid_col = 1,
        .grid_row = 2,
    };
    @memcpy(lu.players[0].name[0..3], "Bob");

    try encode(fbs.writer(), .lobby_update, lu);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_lobby_update(fbs.reader());

    try std.testing.expectApproxEqAbs(@as(f32, 2.5), decoded.round_duration, 0.001);
    try std.testing.expectEqual(@as(u8, 0), decoded.player_id);
    try std.testing.expectEqual(@as(u8, 1), decoded.player_count);
}

test "round-trip: game_start — round_duration survives" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const label = "wave_01";
    var gs = GameStart{
        .wave_label = [_]u8{0} ** 32,
        .wave_label_len = @intCast(label.len),
        .player_id = 3,
        .round_duration = 4.0,
    };
    @memcpy(gs.wave_label[0..label.len], label);

    try encode(fbs.writer(), .game_start, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_start(fbs.reader());

    try std.testing.expectApproxEqAbs(@as(f32, 4.0), decoded.round_duration, 0.001);
    try std.testing.expectEqual(@as(u8, 3), decoded.player_id);
    try std.testing.expectEqualSlices(u8, label, decoded.wave_label[0..decoded.wave_label_len]);
}

test "round-trip: action_result shield tag" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const ar = ActionResult{
        .tag = .shield,
        .actor_entity = std.math.maxInt(u32),
        .target_entity = 5,
        .value = 3,
    };
    try encode(fbs.writer(), .action_result, ar);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_action_result(fbs.reader());

    try std.testing.expectEqual(ActionResultTag.shield, decoded.tag);
    try std.testing.expectEqual(@as(u32, 5), decoded.target_entity);
    try std.testing.expectEqual(@as(u16, 3), decoded.value);
}
