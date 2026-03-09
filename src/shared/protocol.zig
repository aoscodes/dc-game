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

// ---------------------------------------------------------------------------
// Message tags
// ---------------------------------------------------------------------------

pub const MsgTag = enum(u8) {
    // ---- Client → Server ------------------------------------------------
    /// First message on a fresh connection.
    /// Payload: JoinLobby
    join_lobby = 0x01,
    /// Set or change the player's chosen class.
    /// Payload: ChooseClass
    choose_class = 0x02,
    /// Player signals they are ready to start.
    /// Payload: none (tag only)
    ready_up = 0x03,
    /// Submit an action for the player's character when it is their turn.
    /// Payload: ChooseAction
    choose_action = 0x04,
    /// Sent on reconnect before any other message.
    /// Payload: Reconnect
    reconnect = 0x05,

    // ---- Server → Client ------------------------------------------------
    /// Broadcast current lobby state after any change.
    /// Payload: LobbyUpdate
    lobby_update = 0x10,
    /// Sent to all clients when the game starts.
    /// Payload: GameStart
    game_start = 0x11,
    /// Full game-state snapshot; sent on every server tick and after actions.
    /// Payload: GameState
    game_state = 0x12,
    /// Result of a resolved action (damage dealt, HP restored, etc.).
    /// Payload: ActionResult
    action_result = 0x13,
    /// Tells the owning client their character's ATB gauge is full.
    /// Payload: YourTurn
    your_turn = 0x14,
    /// Game has ended.
    /// Payload: GameOver
    game_over = 0x15,
    /// Server rejected a message from the client (e.g. out-of-turn action).
    /// Payload: Error
    @"error" = 0x1F,
};

// ---------------------------------------------------------------------------
// Client → Server payloads
// ---------------------------------------------------------------------------

pub const JoinLobby = struct {
    /// Display name; 1–16 ASCII bytes.
    name: [16]u8,
    /// Actual length of name (0 < name_len <= 16).
    name_len: u8,
};

pub const ChooseClass = struct {
    class: components.ClassTag,
};

/// No payload struct needed for ready_up (tag-only message).
pub const ActionTag = enum(u8) {
    attack = 0,
    defend = 1,
};

pub const ChooseAction = struct {
    action: ActionTag,
    /// Target entity ID.  Ignored (set to 0) when action == .defend.
    target_entity: u32,
};

pub const Reconnect = struct {
    player_id: u8,
};

// ---------------------------------------------------------------------------
// Server → Client payloads
// ---------------------------------------------------------------------------

pub const MAX_PLAYERS: u8 = 6;

pub const PlayerInfo = struct {
    player_id: u8,
    name: [16]u8,
    name_len: u8,
    class: components.ClassTag,
    ready: bool,
    connected: bool,
};

pub const LobbyUpdate = struct {
    join_code: [6]u8,
    player_count: u8,
    players: [MAX_PLAYERS]PlayerInfo,
    /// The player_id assigned to the recipient of this message.
    /// Each client receives a different value; 0xFF = unassigned.
    your_player_id: u8,
};

pub const GameStart = struct {
    /// Label of the first wave being loaded.
    wave_label: [32]u8,
    wave_label_len: u8,
    /// The player_id assigned to this client's character.
    your_player_id: u8,
};

/// One entity's state in the game-state snapshot.
pub const EntitySnapshot = struct {
    entity: u32,
    grid_col: u8,
    grid_row: u8,
    hp_current: u16,
    hp_max: u16,
    atb_gauge: f32,
    action_state: components.ActionStateTag,
    class: components.ClassTag,
    team: components.TeamId,
    /// player_id of controlling client; 0xFF = AI / no owner.
    owner: u8,
};

pub const MAX_ENTITIES_WIRE: u16 = 64; // max entities we send in one snapshot

pub const GameState = struct {
    /// Server tick counter; clients use for ordering.
    tick: u32,
    entity_count: u8,
    entities: [MAX_ENTITIES_WIRE]EntitySnapshot,
};

pub const ActionResultTag = enum(u8) {
    damage = 0,
    heal = 1,
    defend = 2,
    miss = 3,
    death = 4,
};

pub const ActionResult = struct {
    tag: ActionResultTag,
    actor_entity: u32,
    target_entity: u32,
    /// Damage dealt, HP restored, etc.  0 for defend/miss.
    value: u16,
};

pub const YourTurn = struct {
    entity: u32,
};

pub const WinnerId = enum(u8) {
    players = 0,
    enemies = 1,
};

pub const GameOver = struct {
    winner: WinnerId,
};

pub const Error = struct {
    /// Short ASCII message; 0-terminated.
    message: [64]u8,
};

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

/// Writes a complete message (tag + payload) to `writer`.
/// Caller provides a fixed-size stack buffer via `writer`.
pub fn encode(writer: anytype, comptime tag: MsgTag, payload: anytype) !void {
    try writer.writeByte(@intFromEnum(tag));
    const T = @TypeOf(payload);

    // Tag-only messages have a void payload.
    if (T == void) return;

    switch (tag) {
        .join_lobby => try encode_join_lobby(writer, payload),
        .choose_class => try writer.writeByte(@intFromEnum(payload.class)),
        .ready_up => {},
        .choose_action => try encode_choose_action(writer, payload),
        .reconnect => try writer.writeByte(payload.player_id),

        .lobby_update => try encode_lobby_update(writer, payload),
        .game_start => try encode_game_start(writer, payload),
        .game_state => try encode_game_state(writer, payload),
        .action_result => try encode_action_result(writer, payload),
        .your_turn => try writer.writeInt(u32, payload.entity, .little),
        .game_over => try writer.writeByte(@intFromEnum(payload.winner)),
        .@"error" => try writer.writeAll(&payload.message),
    }
}

fn encode_join_lobby(w: anytype, p: JoinLobby) !void {
    try w.writeByte(p.name_len);
    try w.writeAll(p.name[0..p.name_len]);
}

fn encode_choose_action(w: anytype, p: ChooseAction) !void {
    try w.writeByte(@intFromEnum(p.action));
    try w.writeInt(u32, p.target_entity, .little);
}

fn encode_lobby_update(w: anytype, p: LobbyUpdate) !void {
    try w.writeAll(&p.join_code);
    try w.writeByte(p.player_count);
    try w.writeByte(p.your_player_id);
    var i: u8 = 0;
    while (i < p.player_count) : (i += 1) {
        const pl = p.players[i];
        try w.writeByte(pl.player_id);
        try w.writeByte(pl.name_len);
        try w.writeAll(pl.name[0..pl.name_len]);
        try w.writeByte(@intFromEnum(pl.class));
        try w.writeByte(if (pl.ready) 1 else 0);
        try w.writeByte(if (pl.connected) 1 else 0);
    }
}

fn encode_game_start(w: anytype, p: GameStart) !void {
    try w.writeByte(p.wave_label_len);
    try w.writeAll(p.wave_label[0..p.wave_label_len]);
    try w.writeByte(p.your_player_id);
}

fn encode_game_state(w: anytype, p: GameState) !void {
    try w.writeInt(u32, p.tick, .little);
    try w.writeByte(p.entity_count);
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        const e = p.entities[i];
        try w.writeInt(u32, e.entity, .little);
        try w.writeByte(e.grid_col);
        try w.writeByte(e.grid_row);
        try w.writeInt(u16, e.hp_current, .little);
        try w.writeInt(u16, e.hp_max, .little);
        try w.writeAll(std.mem.asBytes(&e.atb_gauge));
        try w.writeByte(@intFromEnum(e.action_state));
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

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

pub const DecodeError = error{
    UnknownTag,
    InvalidClass,
    InvalidActionTag,
    InvalidTeam,
    InvalidActionState,
    InvalidWinner,
    NameTooLong,
    TooManyEntities,
};

/// Reads the 1-byte tag from `reader` and returns it.
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
    const action_byte = try reader.readByte();
    const action = std.meta.intToEnum(ActionTag, action_byte) catch
        return DecodeError.InvalidActionTag;
    const target = try reader.readInt(u32, .little);
    return .{ .action = action, .target_entity = target };
}

pub fn decode_reconnect(reader: anytype) !Reconnect {
    return .{ .player_id = try reader.readByte() };
}

pub fn decode_lobby_update(reader: anytype) !LobbyUpdate {
    var p: LobbyUpdate = undefined;
    _ = try reader.readAll(&p.join_code);
    p.player_count = try reader.readByte();
    p.your_player_id = try reader.readByte();
    if (p.player_count > MAX_PLAYERS) return DecodeError.TooManyEntities;
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
    }
    return p;
}

pub fn decode_game_start(reader: anytype) !GameStart {
    var p: GameStart = undefined;
    const llen = try reader.readByte();
    p.wave_label = [_]u8{0} ** 32;
    p.wave_label_len = llen;
    _ = try reader.readAll(p.wave_label[0..llen]);
    p.your_player_id = try reader.readByte();
    return p;
}

pub fn decode_game_state(reader: anytype) !GameState {
    var p: GameState = undefined;
    p.tick = try reader.readInt(u32, .little);
    p.entity_count = try reader.readByte();
    if (p.entity_count > MAX_ENTITIES_WIRE) return DecodeError.TooManyEntities;
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        var e: EntitySnapshot = undefined;
        e.entity = try reader.readInt(u32, .little);
        e.grid_col = try reader.readByte();
        e.grid_row = try reader.readByte();
        e.hp_current = try reader.readInt(u16, .little);
        e.hp_max = try reader.readInt(u16, .little);
        var gauge_bytes: [4]u8 = undefined;
        _ = try reader.readAll(&gauge_bytes);
        e.atb_gauge = std.mem.bytesToValue(f32, &gauge_bytes);
        const as_byte = try reader.readByte();
        e.action_state = std.meta.intToEnum(components.ActionStateTag, as_byte) catch
            return DecodeError.InvalidActionState;
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
        return DecodeError.InvalidActionTag;
    return .{
        .tag = tag,
        .actor_entity = try reader.readInt(u32, .little),
        .target_entity = try reader.readInt(u32, .little),
        .value = try reader.readInt(u16, .little),
    };
}

pub fn decode_your_turn(reader: anytype) !YourTurn {
    return .{ .entity = try reader.readInt(u32, .little) };
}

pub fn decode_game_over(reader: anytype) !GameOver {
    const byte = try reader.readByte();
    const winner = std.meta.intToEnum(WinnerId, byte) catch
        return DecodeError.InvalidWinner;
    return .{ .winner = winner };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "round-trip: choose_action" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const msg = ChooseAction{ .action = .attack, .target_entity = 42 };
    try encode(fbs.writer(), .choose_action, msg);

    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.choose_action, tag);
    const decoded = try decode_choose_action(fbs.reader());
    try std.testing.expectEqual(msg.action, decoded.action);
    try std.testing.expectEqual(msg.target_entity, decoded.target_entity);
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
