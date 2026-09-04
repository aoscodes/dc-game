//! Balance *types* for the Slime Feast encounter.
//!
//! The actual numbers live in `data/balance.json` and are loaded at server
//! start by `config.zig` — designers tune the JSON, no rebuild required.
//! The browser fetches the same file, so there is a single source of truth
//! for rates and recipe tables (wire messages reference recipes by table
//! index, in file order).
//!
//! ## Moves
//!
//! A move names a SHAPE and a CHARGE COST.  Casting stamps that shape on the
//! grid anchored at the caster's cursor: every covered hazard cell is
//! downgraded one tier.
//!
//! `player_recipes` is an ordered CYCLE: each player has one move selected and
//! steps the selection forward/backward a slot at a time (see
//! session.cycle_selection).  Table order is therefore player-facing — it is the
//! order the wheel turns in — and a move's index is its identity on the wire.
//! There is no way to name a move that is not in the table, so the table is the
//! complete move list and a cast can only fail on price.
//!
//! ## Charges
//!
//! Charges are the encounter's scarce resource: ONE pool, shared by the whole
//! team, spent across the WHOLE game and never refilled (the starting amount is
//! per-encounter — see encounters.json).  Each move prices itself via `cost`,
//! so the move table is also the economy: broad shapes can be made expensive
//! and precise ones cheap.  A cast that would take the TURN over the pool is
//! refused outright — nothing is spent and nothing lands.
//!
//! ## Group moves
//!
//! A group move (`team_recipes`) is a bigger shape that no single player can
//! cast: it names a bag of ordinary moves (`moves`) which DISTINCT players must
//! cast on the SAME square within one turn.  Every cast still stamps its own
//! shape as it lands; the cast that completes the bag stamps the group shape
//! *instead of* its own, and pays the group's cost rather than its own (see
//! game_logic.complete_group).  So a group is discovered by playing normally
//! into the same cell, not by holding a cast back — nothing is ever escrowed,
//! and there is no state to lose at turn end.

const std = @import("std");
const c = @import("components.zig");

/// Wire cap on the player recipe table (MatchStats hit-array sizing).
/// The config loader rejects data files exceeding it.
pub const MAX_PLAYER_RECIPES: u8 = 64;
/// Wire cap on the team recipe table.
pub const MAX_TEAM_RECIPES: u8 = 64;

/// Bounding-box cap on a single shape.  A shape must fit the grid caps, since
/// a shape larger than the playfield could never land fully.
pub const MAX_SHAPE_ROWS: u8 = c.MAX_GRID_ROWS;
pub const MAX_SHAPE_COLS: u8 = c.MAX_GRID_COLS;
pub const MAX_SHAPE_CELLS: u16 = @as(u16, MAX_SHAPE_ROWS) * @as(u16, MAX_SHAPE_COLS);

/// Array cap on a group move's component bag.  A group cannot need more
/// contributors than there are players, and config.zig rejects a bag exceeding
/// protocol.MAX_PLAYERS; this is the looser static bound (protocol imports
/// balance, so balance cannot import protocol to reuse it).
pub const MAX_TEAM_COMPONENTS: u8 = 8;

/// One cell of a shape, as a SIGNED offset from the shape's anchor.  Signed
/// because the anchor is the bounding box's centre, so cells reach up/left of
/// it; the grid clips whatever falls outside (see slime.apply_shape).
pub const ShapeOffset = struct {
    d_row: i8,
    d_col: i8,
};

/// The footprint a cast stamps on the grid: the set of cells it covers,
/// relative to the anchor cell the player aims at.
///
/// Orientation is FIXED — rotations and reflections are authored as separate
/// recipes, so every distinct footprint is its own entry on the shape wheel and
/// the move list stays explicit.
///
/// Built by `config.zig` from JSON rows of `#`/`.` characters, e.g.
/// `[".#.", "###", ".#."]` is a plus.  The anchor is the bounding box centre
/// (rounded down), so odd-sized shapes centre on the aimed cell.
pub const Shape = struct {
    /// Covered cells, in row-major order of the authored rows.  Never empty:
    /// the loader rejects a shape with no `#`.
    offsets: []const ShapeOffset,
    /// Bounding box of the authored rows, for previews and validation.
    rows: u8,
    cols: u8,

    /// Number of cells this shape covers when it lands fully on the grid.
    pub fn size(self: Shape) usize {
        return self.offsets.len;
    }
};

/// Charges a recipe costs when `cost` is absent from its JSON entry.
pub const DEFAULT_RECIPE_COST: u16 = 1;

/// One selectable move.  Its INDEX in `Balance.player_recipes` is its identity:
/// the wire sends a selection as an index, and group moves name their components
/// by index too.
pub const PlayerRecipe = struct {
    label: []const u8,
    /// Footprint downgraded at the caster's cursor.  Every move names a
    /// shape — the stamp IS the cast's whole effect.
    shape: Shape,
    /// Charges deducted from the team pool when this move fires.  May be 0
    /// for a deliberately free move.  A lock-in is refused when the whole
    /// turn's quote, this move included, exceeds what the pool holds.
    cost: u16 = DEFAULT_RECIPE_COST,
};

/// A shape too big for one player: it fires when DISTINCT players have cast the
/// moves in `components` on one square during a single turn.
pub const TeamRecipe = struct {
    label: []const u8,
    /// Indices into `Balance.player_recipes` — the moves that must land on the
    /// square, as a BAG (order is irrelevant, repeats are allowed and each
    /// repeat needs another player).  Resolved from JSON move labels by
    /// config.zig, so the data file names components the way designers do.
    components: []const u8,
    shape: Shape,
    /// Charges deducted ONCE when the group fires, INSTEAD of the completing
    /// cast's own cost.  The earlier component casts already paid their own way
    /// as they landed, so this is the price of the upgrade, not of the whole
    /// group.
    cost: u16 = DEFAULT_RECIPE_COST,
};

/// Slime grid dimensions — a GLOBAL knob (not per-encounter), so every game
/// presents the same playfield shape and the renderer's layout is stable.
/// Validated by config.zig against components.MAX_GRID_ROWS/COLS.
pub const SlimeGridDims = struct {
    rows: u8,
    cols: u8,

    /// Live cell count of a grid with these dimensions.
    pub fn cells(self: SlimeGridDims) u16 {
        return @as(u16, self.rows) * @as(u16, self.cols);
    }
};

/// Default grid used when `slime_grid` is absent from balance.json.
pub const DEFAULT_SLIME_GRID = SlimeGridDims{ .rows = 6, .cols = 10 };

/// Defaults for the appetite → hunger formula, used when the fields are
/// absent from balance.json.  See `game_logic.player_hunger` for the formula
/// itself; the board firmware mirrors it (board/src/game/balance.c
/// balance_player_hunger), so a change here should be made there too.
pub const DEFAULT_HUNGER_BASE: u16 = 30;
pub const DEFAULT_APPETITE_SCALE: u16 = 5;
pub const DEFAULT_HUNGER_PLAYER_CAP: u16 = 500;

/// Default run length a matchable special kind needs, used when a kind is
/// absent from balance.json's `specials` table.
pub const DEFAULT_MATCH_LEN: u8 = 3;

/// Default hunger capacity each baby Lil Guy adds to the pool, used when
/// `baby_hunger` is absent from balance.json.  Mirrored by the board firmware
/// (board/src/game/balance.c), so a change here should be made there too.
pub const DEFAULT_BABY_HUNGER: u16 = 10;

/// Default charges one carried Neutralizer Canister adds to the team pool,
/// used when `powerups` is absent from balance.json.
pub const DEFAULT_NEUTRALIZER_CANISTER_CHARGES: u16 = 10;

/// Default width of the turn-end bite, in grid columns from the left edge,
/// used when `feast_columns` is absent from balance.json.  The first Lil Guy
/// always eats at least one column.
pub const DEFAULT_FEAST_COLUMNS: u8 = 1;

/// Default EXTRA bite columns each seated Lil Guy adds, used when
/// `feast_columns_per_guy` is absent from balance.json.  0 = the crowd's size
/// is purely visual.
pub const DEFAULT_FEAST_COLUMNS_PER_GUY: u8 = 0;

/// The BACK RANKS: how many of the grid's rightmost columns a
/// `back_ranks_only` special kind may spawn in — the columns farthest from
/// the feast's door on the left edge.  Mirrored by the board firmware
/// (board/src/game/balance.c), so a change here should be made there too.
pub const BACK_RANKS: u8 = 2;

/// Default charges a swallowed canister refills, used when `charge_refill`
/// is absent from balance.json's `specials` table.  Mirrored by the board
/// firmware (board/src/game/balance.c), so a change here should be made
/// there too.
pub const DEFAULT_CHARGE_REFILL: u16 = 3;

/// Default cap on how many links a reaction CHAIN may run past the thing
/// that started it (see Balance.max_chain_depth).
pub const DEFAULT_MAX_CHAIN_DEPTH: u8 = 3;

/// Which trigger fires a special's effect (components.SpecialKind.eat_effect).
///
/// The effect itself is hard-coded per kind; this only chooses WHEN it goes
/// off.  Whichever trigger fires it CONSUMES the unit — activation removes it
/// from the grid before the effect runs — so under `eatcast` the first
/// trigger to reach it wins and the other never sees it.
pub const Activation = enum {
    /// Fires when the bite SWALLOWS it.  The original behaviour, and the
    /// default: a cast covering the unit does nothing (it counts `inert`).
    eat,
    /// Fires when an Agent block COVERS it — a player's cast, or another
    /// block in the same chain.  The bite can still eat the unit, but eating
    /// it fires nothing: the effect is lost, which is the whole tension.
    /// Cast activation scores nothing and costs no hunger; a cast does not
    /// feed the Lil Guys.
    cast,
    /// Fires on EITHER trigger, whichever arrives first.
    eatcast,

    /// True if an Agent block covering a unit of this kind sets it off.
    pub fn on_cast(self: Activation) bool {
        return self == .cast or self == .eatcast;
    }

    /// True if swallowing a unit of this kind sets it off.
    pub fn on_eat(self: Activation) bool {
        return self == .eat or self == .eatcast;
    }
};

/// Designer knobs for the POWERUPS a badge carries into an encounter.
///
/// What each powerup DOES is hard-coded (see server/session.zig); this tunes
/// only its numbers.  One flat field per kind rather than a per-kind array
/// like `specials`, because powerups share no knobs with each other: a
/// canister's charges and a future powerup's effect have nothing in common to
/// factor out, and a common struct would be mostly-ignored fields on every
/// kind — the failure mode SpecialTuning already lives with.
pub const PowerupTuning = struct {
    /// Charges added to the team pool for each Neutralizer Canister a SEATED
    /// player carries.  Granted when they sit (after their share of the pool
    /// is grown) and taken back when they leave (before their share shrinks),
    /// so sitting down and standing up again is a round trip, not a mint.
    neutralizer_canister_charges: u16 = DEFAULT_NEUTRALIZER_CANISTER_CHARGES,
};

/// Designer knobs for one SpecialKind.  What a kind DOES is hard-coded
/// (components.SpecialKind); this tunes only its numbers.
pub const SpecialTuning = struct {
    /// Same-kind cells that must sit contiguously in one row or column
    /// (after the turn-end refill) to fire the kind's match effect.  Ignored
    /// for kinds with no match behaviour — which today is EVERY kind: the
    /// match machinery is dormant, and this knob waits with it.  The loader
    /// keeps it within 2..max(grid rows, cols) so a match is always
    /// physically possible.
    match_len: u8 = DEFAULT_MATCH_LEN,
    /// When true, the kind may only ENTER the field in the rightmost
    /// `BACK_RANKS` columns — the far side from the Lil Guys' mouths on the
    /// left edge.  An ENTRY restriction only: the conveyor drifts every unit
    /// leftward as the columns ahead of it are eaten, so the kind arrives at
    /// the back and rides the whole board before it is bitten.  A fill whose
    /// reservoir holds only restricted kinds leaves front cells empty rather
    /// than seating one (see slime.fill).  On a grid of `BACK_RANKS` columns
    /// or fewer the restriction covers every cell and is a no-op.
    back_ranks_only: bool = false,
    /// When true, at least one unit of the kind is seated on the grid at the
    /// START OF PLAY whenever the encounter's supply holds any: before the
    /// initial fill, one unit is placed in a uniform-random cell that the
    /// kind's spawn rules allow (see slime.SlimeField.init).  Only the
    /// initial fill is affected — mid-game refills stay pure reservoir
    /// draws.  A no-op when the supply holds none of the kind or no cell is
    /// eligible.
    guaranteed_at_start: bool = false,
    /// Charges refilled into the team pool when one of this kind is
    /// swallowed.  Only meaningful for kinds whose eat effect is
    /// `refill_charges` (the canister); ignored for every other kind.
    charge_refill: u16 = DEFAULT_CHARGE_REFILL,
    /// When true, the kind's explosion destroys ONLY rocks — everything
    /// else in the blast survives.  Only meaningful for kinds whose eat
    /// effect is `explode` (the bomb); ignored for every other kind.
    explode_rocks_only: bool = false,
    /// When true, the bite GNAWS a unit of this kind it cannot swallow:
    /// hunger is filled by `hunger_cost_normal` and nothing else happens —
    /// no score, no downgrade, the unit stays put and is gnawed again next
    /// bite.  Only meaningful for INCONSUMABLE kinds (the rock); a kind the
    /// bite can swallow is eaten before this is consulted, so the flag is
    /// ignored for every other kind.
    ///
    /// Off, a rock is inert: it neither feeds the Lil Guys nor moves, so a
    /// field of nothing but rocks and no charges to break them can never
    /// end (see slime.SlimeField.feast).  On, the mouths chew stone for
    /// nothing — the clock always advances, at the price of making a rock a
    /// live drain on hunger rather than dead weight.
    bite_costs_hunger: bool = false,
    /// WHEN this kind's effect fires (see Activation).  `.eat` — the
    /// default — is the original game: only the bite sets a special off, and
    /// a cast that covers one achieves nothing.
    ///
    /// The loader rejects anything but `.eat` for kinds whose cast path is
    /// not wired: the egg (a cast-hatched baby would need the session's PRNG
    /// to roll its type), the canister (a cast-credited refill), and the
    /// rock (inconsumable, so it has no effect to fire — a cast BREAKS it
    /// instead, see slime.apply_shape).
    activate_on: Activation = .eat,
};

/// All designer-tunable balance numbers.  Loaded from `data/balance.json`
/// (see config.zig); tests use the frozen fixture in fixtures.zig.
pub const Balance = struct {
    /// Hunger cost per BITE — a consumed edible unit and a downgraded hazard
    /// both fill the bar by this much.  The bar is the game's clock: every
    /// bite runs it down toward the encounter's end.
    hunger_cost_normal: u32,
    /// How many links a reaction CHAIN may run past the thing that started
    /// it.  The stamp that begins a chain is depth 0; a special it activates
    /// fires its own effect at depth 1, whatever that effect activates goes
    /// at depth 2, and so on while `depth <= max_chain_depth`.  At 0 a cast
    /// still activates the specials it covers, but their blocks and blasts
    /// set nothing further off.
    ///
    /// This is a LEGIBILITY limit, not a safety rail.  A chain cannot run
    /// away regardless: every link removes a unit from the grid before it
    /// fires, so the BOARD is the real bound and the cap only exists so a
    /// cascade stays something a player can follow.  (The invariant that
    /// actually matters is the ordering — see slime.SlimeField.activate.)
    ///
    /// Note the type: a u8 tops out at 255 while the largest grid holds 256
    /// cells, so the deepest chain a board can supply is one longer than the
    /// biggest cap that can be written here.  slime.stamp therefore counts
    /// depth in a WIDER integer than this.
    max_chain_depth: u8 = DEFAULT_MAX_CHAIN_DEPTH,
    /// When true, a bomb DESTROYED by another bomb's blast detonates itself
    /// instead of merely dying — the chain reaction.  A property of the
    /// BLAST, not of what set the first bomb off, so it applies just the
    /// same to a bomb the Lil Guys swallowed.
    ///
    /// Dead in combination with the bomb's `explode_rocks_only`: a blast
    /// that spares everything but rocks never destroys a bomb, so there is
    /// nothing to chain to.
    blast_chains: bool = false,
    /// Dimensions of the slime grid.  Slime beyond `rows * cols` waits in the
    /// off-grid reservoir and refills emptied cells at the start of each turn.
    slime_grid: SlimeGridDims,
    /// Base ms between BITE events — the realtime clock the Lil Guys chew
    /// on.  The crowd speeds it up (see `bite_interval_effective`); the game
    /// idles biteless while nobody is seated.
    bite_interval_ms: u32 = DEFAULT_BITE_INTERVAL_MS,
    /// Percent each seated Lil Guy PAST THE FIRST adds to the bite rate.
    /// Additive: 2 extra guys at 15% = rate x1.30.
    bite_speedup_per_guy_pct: u16 = DEFAULT_BITE_SPEEDUP_PER_GUY_PCT,
    /// Percent each baby Lil Guy at the table (board-brought AND hatched)
    /// adds to the bite rate.  Independent of the per-guy knob, and additive
    /// with it.
    bite_speedup_per_baby_pct: u16 = DEFAULT_BITE_SPEEDUP_PER_BABY_PCT,
    /// Ms a player must wait between casts.  A press inside the cooldown is
    /// ignored; 0 = no cooldown.
    cast_cooldown_ms: u32 = DEFAULT_CAST_COOLDOWN_MS,
    /// Ms window in which DISTINCT players' component casts on one square
    /// spell a team recipe (see game_logic.complete_group).
    team_window_ms: u32 = DEFAULT_TEAM_WINDOW_MS,
    /// Ms after a bite settles in which NO player may cast: the Lil Guys are
    /// chewing and the board is not yours to write on.  Unlike
    /// `cast_cooldown_ms` this is one table-wide window, not per-player, and
    /// a press inside it is REFUSED out loud (`cast_refused`) rather than
    /// silently dropped — the client shakes the seat panel so the answer is
    /// visible.  0 = no window, and casting stays legal through the whole
    /// meal.  The loader keeps it below `bite_interval_ms`: a window that
    /// outlasts the gap between bites is a table that never accepts a cast.
    settle_lockout_ms: u32 = DEFAULT_SETTLE_LOCKOUT_MS,
    /// Hunger capacity ONE player contributes with an appetite of 0.  The
    /// game's hunger bar capacity is the SUM of every player's contribution
    /// (see game_logic.player_hunger), so this replaces the old per-encounter
    /// `hunger_max`: a bigger team simply has more room to eat.
    hunger_base: u16 = DEFAULT_HUNGER_BASE,
    /// Extra hunger capacity per point of a player's appetite stat (the
    /// board's persistent flash stat, sent when a controller joins).  Linear:
    /// contribution = hunger_base + appetite * appetite_scale.
    appetite_scale: u16 = DEFAULT_APPETITE_SCALE,
    /// Ceiling on ONE player's hunger contribution, however large their
    /// appetite has grown — keeps a veteran board from trivialising the bar.
    hunger_player_cap: u16 = DEFAULT_HUNGER_PLAYER_CAP,
    /// Hunger capacity each baby Lil Guy in the encounter adds to the pool —
    /// babies a board brought AND babies hatched mid-game alike.
    baby_hunger: u16 = DEFAULT_BABY_HUNGER,
    /// Grid columns the turn-end bite covers, counted from the left edge.
    /// The loader keeps it within 1..slime_grid.cols.  See `feast_width` for
    /// how the seated crowd widens it.
    feast_columns: u8 = DEFAULT_FEAST_COLUMNS,
    /// EXTRA bite columns per seated Lil Guy: the bite's total width is
    /// `feast_columns + seated * feast_columns_per_guy`, clamped to the grid.
    /// Babies never count — their only number is `baby_hunger`.
    feast_columns_per_guy: u8 = DEFAULT_FEAST_COLUMNS_PER_GUY,
    /// When true, NO special kind may ever ENTER the field in column 0 —
    /// the cells at the Lil Guys' mouths.  An ENTRY restriction only: the
    /// conveyor drifts units leftward, so a special seated deeper does reach
    /// column 0 eventually — it just never STARTS there.  A fill whose
    /// reservoir holds only specials leaves door cells empty rather than
    /// seating one (see slime.fill).  Mirrored by the board firmware
    /// (board/src/game/balance.c), so a change here should be made there too.
    specials_avoid_door_column: bool = true,
    /// Per-SpecialKind tuning, indexed by SpecialKind ordinal.
    specials: [c.SpecialKind.size]SpecialTuning =
        [_]SpecialTuning{.{}} ** c.SpecialKind.size,
    /// What the powerups a badge carries in are worth.  See PowerupTuning.
    powerups: PowerupTuning = .{},
    player_recipes: []const PlayerRecipe,
    team_recipes: []const TeamRecipe,

    /// Tuning for one special kind.
    pub fn special_tuning(self: *const Balance, kind: c.SpecialKind) SpecialTuning {
        return self.specials[@intFromEnum(kind)];
    }

    /// Width of the turn-end bite for a crowd of `seated` Lil Guys, in grid
    /// columns from the left edge: `feast_columns` plus
    /// `feast_columns_per_guy` per guy, clamped to the grid — the bite can
    /// never be wider than the board.  Mirrored by the browser's replay
    /// (web/game.js feastWidth), so a change here must be made there too.
    pub fn feast_width(self: *const Balance, seated: u32) u8 {
        const extra = @as(u32, self.feast_columns_per_guy) * seated;
        const width = @min(@as(u32, self.feast_columns) + extra, self.slime_grid.cols);
        return @intCast(width);
    }

    /// Ms between bites for a table of `seated` Lil Guys and `babies` baby
    /// Lil Guys.  Additive rate multiplier in integer math:
    /// `base * 100 / (100 + (seated-1)*guy_pct + babies*baby_pct)` — every
    /// extra guy and every baby speeds the SAME base rate, no compounding.
    /// A table of 0 or 1 guys and no babies bites at the base interval.
    /// Never returns 0: the loader keeps bite_interval_ms >= 100, and the
    /// result is floored at 1ms however large the crowd grows.
    pub fn bite_interval_effective(self: *const Balance, seated: u32, babies: u32) u32 {
        const extra_guys: u64 = if (seated > 1) seated - 1 else 0;
        const pct: u64 = 100 +
            extra_guys * self.bite_speedup_per_guy_pct +
            @as(u64, babies) * self.bite_speedup_per_baby_pct;
        const eff = @as(u64, self.bite_interval_ms) * 100 / pct;
        return @intCast(@max(eff, 1));
    }

    /// The cheapest cast in the whole move list.  A team too poor to afford
    /// this has no legal lock-in left: the session turns their cast presses
    /// into passes so turns keep ending (see session's cast handler).
    pub fn cheapest_cost(self: *const Balance) u16 {
        var min: u16 = std.math.maxInt(u16);
        for (self.player_recipes) |r| min = @min(min, r.cost);
        for (self.team_recipes) |r| min = @min(min, r.cost);
        return min;
    }
};

/// Default ms between bite events when `bite_interval_ms` is absent.
pub const DEFAULT_BITE_INTERVAL_MS: u32 = 4000;
/// Default percent each seated Lil Guy past the first speeds the bite rate.
pub const DEFAULT_BITE_SPEEDUP_PER_GUY_PCT: u16 = 15;
/// Default percent each baby Lil Guy speeds the bite rate.
pub const DEFAULT_BITE_SPEEDUP_PER_BABY_PCT: u16 = 5;
/// Default ms a player waits between casts when `cast_cooldown_ms` is absent.
pub const DEFAULT_CAST_COOLDOWN_MS: u32 = 750;
/// Default ms window in which a team recipe's component casts must land.
pub const DEFAULT_TEAM_WINDOW_MS: u32 = 3000;
/// Default settle window when `settle_lockout_ms` is absent: OFF.  The window
/// is scaled to the shipped bite interval, so a config that shortens the
/// interval without saying otherwise should keep casting open rather than
/// inherit a lockout that swallows its whole meal.
pub const DEFAULT_SETTLE_LOCKOUT_MS: u32 = 0;
