const std = @import("std");
const components = @import("components.zig");

pub const MsgTag = enum(u8) {
    join_lobby = 0x01,
    choose_class = 0x02,
    ready_up = 0x03,
    choose_action = 0x04,
    reconnect = 0x05,
    choose_combo = 0x07,
    cancel_combo = 0x08,

    lobby_update = 0x10,
    game_start = 0x11,
    game_state = 0x12,
    action_result = 0x13,
    round_reset = 0x14,
    game_over = 0x15,
};

pub const JoinLobby = struct {
    name: [16]u8,
    name_len: u8,
};

pub const ChooseClass = struct {
    class: components.ClassTag,
};

pub const ChooseAction = struct {
    action: components.ActionChoice,
};

pub const ChooseCombo = struct {
    combo: components.ActionCombo,
};

/// Encode one ComboSlot to a single byte.
/// Action slots use raw ActionChoice value (0x00–0x02).
/// Element slots use 0x80 | raw Element value (0x80–0x83).
fn encode_combo_slot(w: anytype, slot: components.ComboSlot) !void {
    switch (slot) {
        .action  => |a| try w.writeByte(@intFromEnum(a)),
        .element => |e| try w.writeByte(0x80 | @intFromEnum(e)),
    }
}

/// Decode one ComboSlot byte. Returns error on unknown values.
fn decode_combo_slot(byte: u8) !components.ComboSlot {
    if (byte & 0x80 != 0) {
        const raw: u8 = byte & 0x7F;
        const el = std.meta.intToEnum(components.Element, raw) catch
            return DecodeError.InvalidElement;
        return .{ .element = el };
    } else {
        const ac = std.meta.intToEnum(components.ActionChoice, byte) catch
            return DecodeError.InvalidActionChoice;
        return .{ .action = ac };
    }
}

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
    grid_col: u8,
    grid_row: u8,
};

pub const LobbyUpdate = struct {
    join_code: [6]u8,
    player_count: u8,
    players: [MAX_PLAYERS]PlayerInfo,
    player_id: u8,
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
    class: components.ClassTag,
    team: components.TeamId,
    owner: u8,
    combo_len: u8,
    combo_slots: [components.MAX_COMBO_LEN]components.ComboSlot,

    /// A safe blank value (cannot use std.mem.zeroes because ComboSlot is a union).
    pub const blank = EntitySnapshot{
        .entity     = 0,
        .class      = .grunt,
        .team       = .players,
        .owner      = 0xFF,
        .combo_len  = 0,
        .combo_slots = [_]components.ComboSlot{.{ .action = .damage }} ** components.MAX_COMBO_LEN,
    };
};

pub const MAX_ENTITIES_WIRE: u16 = 64;

pub const TeamSummary = struct {
    hp_current: u16,
    hp_max: u16,
};

pub const GameState = struct {
    tick: u32,
    round_timer: f32,
    entity_count: u8,
    entities: [MAX_ENTITIES_WIRE]EntitySnapshot,
    players: TeamSummary,
    enemies: TeamSummary,
    /// Total damage the enemy team intends to deal this round (living enemy count).
    enemy_intent_damage: u16,
    /// Element of the enemy intent: 0xFF = non-elemental, else raw Element ordinal (0–3).
    enemy_intent_element: u8,
    /// Damage-over-time stacks currently on the player party, indexed by Element ordinal
    /// (0=fire, 1=earth, 2=wind, 3=water).  Each stack deals 1 damage of that element
    /// per round.  Saturated to u8 from the session's u16 counter.
    player_dot_stacks: [4]u8,
    /// DoT stacks currently on the enemy side; same layout as player_dot_stacks.
    enemy_dot_stacks: [4]u8,

    pub const INTENT_ELEMENT_NONE: u8 = 0xFF;

    pub const blank = GameState{
        .tick                = 0,
        .round_timer         = 0,
        .entity_count        = 0,
        .entities            = [_]EntitySnapshot{EntitySnapshot.blank} ** MAX_ENTITIES_WIRE,
        .players             = .{ .hp_current = 0, .hp_max = 0 },
        .enemies             = .{ .hp_current = 0, .hp_max = 0 },
        .enemy_intent_damage  = 0,
        .enemy_intent_element = INTENT_ELEMENT_NONE,
        .player_dot_stacks    = [_]u8{0} ** 4,
        .enemy_dot_stacks     = [_]u8{0} ** 4,
    };
};

pub const ActionResultTag = enum(u8) {
    damage = 0,
    heal = 1,
    shield = 2,
    death = 4,
};

pub const ActionResult = struct {
    tag: ActionResultTag,
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
        .choose_combo => {
            try writer.writeByte(payload.combo.len);
            for (payload.combo.slots[0..payload.combo.len]) |slot|
                try encode_combo_slot(writer, slot);
        },
        .cancel_combo => {},
        .round_reset => {},

        .lobby_update => try encode_lobby_update(writer, payload),
        .game_start => try encode_game_start(writer, payload),
        .game_state => try encode_game_state(writer, payload),
        .action_result => try encode_action_result(writer, payload),
        .game_over => try writer.writeByte(@intFromEnum(payload.winner)),
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
    try w.writeInt(u32, @bitCast(p.round_duration), .little);
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
    try w.writeInt(u32, @bitCast(p.round_duration), .little);
}

fn encode_team_summary(w: anytype, s: TeamSummary) !void {
    try w.writeInt(u16, s.hp_current, .little);
    try w.writeInt(u16, s.hp_max, .little);
}

fn encode_game_state(w: anytype, p: GameState) !void {
    try w.writeInt(u32, p.tick, .little);
    try w.writeInt(u32, @bitCast(p.round_timer), .little);
    try w.writeByte(p.entity_count);
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        const e = p.entities[i];
        try w.writeInt(u32, e.entity, .little);
        try w.writeByte(@intFromEnum(e.class));
        try w.writeByte(@intFromEnum(e.team));
        try w.writeByte(e.owner);
        try w.writeByte(e.combo_len);
        var j: u8 = 0;
        while (j < e.combo_len) : (j += 1)
            try encode_combo_slot(w, e.combo_slots[j]);
    }
    try encode_team_summary(w, p.players);
    try encode_team_summary(w, p.enemies);
    try w.writeInt(u16, p.enemy_intent_damage, .little);
    try w.writeByte(p.enemy_intent_element);
    try w.writeAll(&p.player_dot_stacks);
    try w.writeAll(&p.enemy_dot_stacks);
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
    InvalidElement,
    InvalidTeam,
    InvalidActionResultTag,
    InvalidWinner,
    NameTooLong,
    TooManyEntities,
    InvalidComboLen,
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

pub fn decode_choose_combo(reader: anytype) !ChooseCombo {
    const len = try reader.readByte();
    if (len == 0 or len > components.MAX_COMBO_LEN) return DecodeError.InvalidComboLen;
    var combo = components.ActionCombo{
        .slots = [_]components.ComboSlot{.{ .action = .damage }} ** components.MAX_COMBO_LEN,
        .len = len,
    };
    var i: u8 = 0;
    while (i < len) : (i += 1) {
        const byte = try reader.readByte();
        combo.slots[i] = try decode_combo_slot(byte);
    }
    return .{ .combo = combo };
}

pub fn decode_reconnect(reader: anytype) !Reconnect {
    return .{ .player_id = try reader.readByte() };
}

pub fn decode_lobby_update(reader: anytype) !LobbyUpdate {
    var p: LobbyUpdate = undefined;
    _ = try reader.readAll(&p.join_code);
    p.player_count = try reader.readByte();
    p.player_id = try reader.readByte();
    if (p.player_count > MAX_PLAYERS) return DecodeError.TooManyEntities;
    p.round_duration = @bitCast(try reader.readInt(u32, .little));
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
    p.round_duration = @bitCast(try reader.readInt(u32, .little));
    return p;
}

fn decode_team_summary(reader: anytype) !TeamSummary {
    return .{
        .hp_current = try reader.readInt(u16, .little),
        .hp_max = try reader.readInt(u16, .little),
    };
}

pub fn decode_game_state(reader: anytype) !GameState {
    var p: GameState = undefined;
    p.tick = try reader.readInt(u32, .little);
    p.round_timer = @bitCast(try reader.readInt(u32, .little));
    p.entity_count = try reader.readByte();
    if (p.entity_count > MAX_ENTITIES_WIRE) return DecodeError.TooManyEntities;
    var i: u8 = 0;
    while (i < p.entity_count) : (i += 1) {
        var e: EntitySnapshot = undefined;
        e.entity = try reader.readInt(u32, .little);
        const class_byte = try reader.readByte();
        e.class = std.meta.intToEnum(components.ClassTag, class_byte) catch
            return DecodeError.InvalidClass;
        const team_byte = try reader.readByte();
        e.team = std.meta.intToEnum(components.TeamId, team_byte) catch
            return DecodeError.InvalidTeam;
        e.owner = try reader.readByte();
        e.combo_len = try reader.readByte();
        if (e.combo_len > components.MAX_COMBO_LEN) return DecodeError.InvalidComboLen;
        e.combo_slots = [_]components.ComboSlot{.{ .action = .damage }} ** components.MAX_COMBO_LEN;
        var j: u8 = 0;
        while (j < e.combo_len) : (j += 1) {
            const ab = try reader.readByte();
            e.combo_slots[j] = try decode_combo_slot(ab);
        }
        p.entities[i] = e;
    }
    p.players = try decode_team_summary(reader);
    p.enemies = try decode_team_summary(reader);
    p.enemy_intent_damage  = try reader.readInt(u16, .little);
    p.enemy_intent_element = try reader.readByte();
    _ = try reader.readAll(&p.player_dot_stacks);
    _ = try reader.readAll(&p.enemy_dot_stacks);
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

test "round-trip: game_state — round_timer, team summaries, and combo survive" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState{
        .tick = 42,
        .round_timer = 1.75,
        .entity_count = 1,
        .entities = [_]EntitySnapshot{EntitySnapshot.blank} ** MAX_ENTITIES_WIRE,
        .players = .{ .hp_current = 80, .hp_max = 100 },
        .enemies = .{ .hp_current = 240, .hp_max = 240 },
        .enemy_intent_damage  = 0,
        .enemy_intent_element = GameState.INTENT_ELEMENT_NONE,
        .player_dot_stacks    = [_]u8{0} ** 4,
        .enemy_dot_stacks     = [_]u8{0} ** 4,
    };
    gs.entities[0] = EntitySnapshot{
        .entity = 7,
        .class = .fighter,
        .team = .players,
        .owner = 0,
        .combo_len = 2,
        .combo_slots = [_]components.ComboSlot{
            .{ .action = .damage },
            .{ .action = .shield },
            .{ .action = .damage },
            .{ .action = .damage },
        },
    };

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.game_state, tag);
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u32, 42), decoded.tick);
    try std.testing.expectApproxEqAbs(@as(f32, 1.75), decoded.round_timer, 0.001);
    try std.testing.expectEqual(@as(u8, 1), decoded.entity_count);
    try std.testing.expectEqual(@as(u16, 80), decoded.players.hp_current);
    try std.testing.expectEqual(@as(u16, 240), decoded.enemies.hp_current);
    try std.testing.expectEqual(@as(u8, 2), decoded.entities[0].combo_len);
    try std.testing.expectEqual(components.ActionChoice.damage, decoded.entities[0].combo_slots[0].action);
    try std.testing.expectEqual(components.ActionChoice.shield, decoded.entities[0].combo_slots[1].action);
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

test "round-trip: choose_combo [damage, shield, heal]" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var combo = components.ActionCombo{
        .slots = [_]components.ComboSlot{.{ .action = .damage }} ** components.MAX_COMBO_LEN,
        .len = 3,
    };
    combo.slots[0] = .{ .action = .damage };
    combo.slots[1] = .{ .action = .shield };
    combo.slots[2] = .{ .action = .heal };

    try encode(fbs.writer(), .choose_combo, ChooseCombo{ .combo = combo });
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.choose_combo, tag);
    const decoded = try decode_choose_combo(fbs.reader());
    try std.testing.expectEqual(@as(u8, 3), decoded.combo.len);
    try std.testing.expectEqual(components.ActionChoice.damage, decoded.combo.slots[0].action);
    try std.testing.expectEqual(components.ActionChoice.shield, decoded.combo.slots[1].action);
    try std.testing.expectEqual(components.ActionChoice.heal,   decoded.combo.slots[2].action);
}

test "round-trip: choose_combo len=4 all damage" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const combo = components.ActionCombo{
        .slots = [_]components.ComboSlot{.{ .action = .damage }} ** components.MAX_COMBO_LEN,
        .len = 4,
    };
    try encode(fbs.writer(), .choose_combo, ChooseCombo{ .combo = combo });
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_choose_combo(fbs.reader());
    try std.testing.expectEqual(@as(u8, 4), decoded.combo.len);
    for (decoded.combo.slots[0..4]) |s|
        try std.testing.expectEqual(components.ActionChoice.damage, s.action);
}

test "round-trip: choose_combo with element slots [fire, damage, water, shield]" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const combo = components.ActionCombo{
        .slots = [_]components.ComboSlot{
            .{ .element = .fire   },
            .{ .action  = .damage },
            .{ .element = .water  },
            .{ .action  = .shield },
        },
        .len = 4,
    };
    try encode(fbs.writer(), .choose_combo, ChooseCombo{ .combo = combo });
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_choose_combo(fbs.reader());
    try std.testing.expectEqual(@as(u8, 4), decoded.combo.len);
    try std.testing.expectEqual(components.Element.fire,          decoded.combo.slots[0].element);
    try std.testing.expectEqual(components.ActionChoice.damage,   decoded.combo.slots[1].action);
    try std.testing.expectEqual(components.Element.water,         decoded.combo.slots[2].element);
    try std.testing.expectEqual(components.ActionChoice.shield,   decoded.combo.slots[3].action);
}

test "round-trip: game_state snapshot with element slot" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState{
        .tick = 1,
        .round_timer = 0.5,
        .entity_count = 1,
        .entities = [_]EntitySnapshot{EntitySnapshot.blank} ** MAX_ENTITIES_WIRE,
        .players = .{ .hp_current = 10, .hp_max = 10 },
        .enemies = .{ .hp_current = 5,  .hp_max = 5  },
        .enemy_intent_damage  = 0,
        .enemy_intent_element = GameState.INTENT_ELEMENT_NONE,
        .player_dot_stacks    = [_]u8{0} ** 4,
        .enemy_dot_stacks     = [_]u8{0} ** 4,
    };
    gs.entities[0] = EntitySnapshot{
        .entity = 1,
        .class  = .mage,
        .team   = .players,
        .owner  = 0,
        .combo_len = 2,
        .combo_slots = [_]components.ComboSlot{
            .{ .element = .earth  },
            .{ .action  = .damage },
            .{ .action  = .damage },
            .{ .action  = .damage },
        },
    };

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_state(fbs.reader());
    try std.testing.expectEqual(@as(u8, 2), decoded.entities[0].combo_len);
    try std.testing.expectEqual(components.Element.earth,        decoded.entities[0].combo_slots[0].element);
    try std.testing.expectEqual(components.ActionChoice.damage,  decoded.entities[0].combo_slots[1].action);
}

test "decode_choose_combo: len=0 returns InvalidComboLen" {
    var buf: [2]u8 = .{ 0x00, 0x00 };
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(DecodeError.InvalidComboLen, decode_choose_combo(fbs.reader()));
}

test "decode_choose_combo: len=5 returns InvalidComboLen" {
    var buf: [2]u8 = .{ 0x05, 0x00 };
    var fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(DecodeError.InvalidComboLen, decode_choose_combo(fbs.reader()));
}

test "round-trip: cancel_combo (zero payload)" {
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .cancel_combo, {});
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.cancel_combo, tag);
}

test "round-trip: round_reset (zero payload)" {
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try encode(fbs.writer(), .round_reset, {});
    fbs.reset();
    const tag = try read_tag(fbs.reader());
    try std.testing.expectEqual(MsgTag.round_reset, tag);
}

test "round-trip: game_state enemy_intent_element fire survives" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState.blank;
    gs.tick = 7;
    gs.enemy_intent_damage  = 3;
    gs.enemy_intent_element = @intFromEnum(components.Element.fire); // 0

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u32, 7), decoded.tick);
    try std.testing.expectEqual(@as(u16, 3), decoded.enemy_intent_damage);
    try std.testing.expectEqual(@intFromEnum(components.Element.fire), decoded.enemy_intent_element);
}

test "round-trip: game_state enemy_intent_element none (0xFF) survives" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState.blank;
    gs.enemy_intent_damage  = 5;
    gs.enemy_intent_element = GameState.INTENT_ELEMENT_NONE;

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqual(@as(u16, 5), decoded.enemy_intent_damage);
    try std.testing.expectEqual(GameState.INTENT_ELEMENT_NONE, decoded.enemy_intent_element);
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

test "round-trip: game_state dot stacks survive encode/decode" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var gs = GameState.blank;
    gs.player_dot_stacks = .{ 3, 0, 1, 0 }; // 3 fire stacks, 1 wind stack on players
    gs.enemy_dot_stacks  = .{ 0, 2, 0, 4 }; // 2 earth, 4 water stacks on enemies

    try encode(fbs.writer(), .game_state, gs);
    fbs.reset();
    _ = try read_tag(fbs.reader());
    const decoded = try decode_game_state(fbs.reader());

    try std.testing.expectEqualSlices(u8, &gs.player_dot_stacks, &decoded.player_dot_stacks);
    try std.testing.expectEqualSlices(u8, &gs.enemy_dot_stacks,  &decoded.enemy_dot_stacks);
}
