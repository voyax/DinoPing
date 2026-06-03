import Foundation

// MARK: - Species

public enum DinoSpecies: String, CaseIterable, Sendable, Hashable {
    case rex
    case plate
    case tri
    case sky
    case long
    case claw

    public var displayName: String {
        switch self {
        case .rex:   "Rex"
        case .plate: "Plate"
        case .tri:   "Tri"
        case .sky:   "Sky"
        case .long:  "Long"
        case .claw:  "Claw"
        }
    }

    /// Stable session-ID → species mapping (FNV-1a). Same session always gets
    /// the same dino across launches, regardless of Swift's per-process
    /// `Hasher` randomization.
    public static func forSession(_ sessionID: String) -> DinoSpecies {
        var hash: UInt64 = 14695981039346656037 // FNV-1a offset
        for byte in sessionID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211 // FNV-1a prime
        }
        return allCases[Int(hash % UInt64(allCases.count))]
    }
}

// MARK: - State

public enum DinoState: Sendable, Hashable {
    case dormant   // 闭眼 / 全村安眠 (1 fps)
    case running   // 奔跑 / 默认工作中 (~7 fps)
    case action    // x_x 求救 (red tint)
    case expanded  // 抬头展示 / 大尺寸 (1 fps, static)
}

// MARK: - Sprite

public struct PixelSprite: Sendable, Hashable {
    public let rows: [String]
    public var width: Int  { rows.first?.count ?? 0 }
    public var height: Int { rows.count }
    public init(_ rows: [String]) { self.rows = rows }
}

// MARK: - Library

public enum DinoSprites {

    /// Frames for a (species, state). Cycle through if more than one.
    public static func frames(_ species: DinoSpecies, _ state: DinoState) -> [PixelSprite] {
        switch (species, state) {
        case (.rex, .dormant):  return [rexSleep]
        case (.rex, .running):  return [rexRunA, rexRunB]
        case (.rex, .action):   return [rexAction]
        case (.rex, .expanded): return [rexExpanded]
        case (_, .dormant), (_, .expanded):
            return [stand(species)]
        case (_, .running), (_, .action):
            return runFrames(species)
        }
    }

    /// Frame rate per state. Single-frame states still use 1 fps so callers
    /// can treat all states uniformly.
    public static func fps(for state: DinoState) -> Double {
        switch state {
        case .dormant:  1
        case .running:  7
        case .action:   6
        case .expanded: 1
        }
    }

    // MARK: Lookup

    private static func stand(_ species: DinoSpecies) -> PixelSprite {
        switch species {
        case .rex:   rexStand
        case .plate: plateStand
        case .tri:   triStand
        case .sky:   skyStand
        case .long:  longStand
        case .claw:  clawStand
        }
    }

    private static func runFrames(_ species: DinoSpecies) -> [PixelSprite] {
        switch species {
        case .rex:   [rexRunA, rexRunB]
        case .plate: [plateRunA, plateRunB]
        case .tri:   [triRunA, triRunB]
        case .sky:   [skyRunA, skyRunB]
        case .long:  [longRunA, longRunB]
        case .claw:  [clawRunA, clawRunB]
        }
    }

    // MARK: - REX (T-Rex)

    // Authentic Chrome offline T-Rex sprite, transcribed pixel-for-pixel
    // from the Chromium source sprite sheet (100-offline-sprite.png). The
    // sprite sheet's sprite is 44×47 at 2x — the logical 1x art is 20×21,
    // which is what these arrays encode.
    //
    // Frame offsets in the source: STANDING x=848, BLINK x=892, RUN1 x=936,
    // RUN2 x=980, CRASHED x=1068. Shadow/anti-alias pixels (R=247) are
    // dropped — only the core dark body pixels survive, which renders as
    // pure white on the black notch.
    static let rexStand = PixelSprite([
        "...........XXXXXXXX.",
        "..........XXXXXXXXXX",
        "..........XX..XXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXX.....",
        "..........XXXXXXXX..",
        "X........XXXXX......",
        "X.......XXXXXX......",
        "XX....XXXXXXXXXX....",
        "XXX..XXXXXXXXX.X....",
        "XXXXXXXXXXXXXX......",
        "XXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXX.......",
        "..XXXXXXXXXXX.......",
        "...XXXXXXXXX........",
        "....XXXXXXX.........",
        ".....XXX.XX.........",
        ".....XX...X.........",
        ".....X....X.........",
    ])

    // RUN 1 — Chrome's first run frame (one leg planted, other tucked back).
    static let rexRunA = PixelSprite([
        "...........XXXXXXXX.",
        "..........XXXXXXXXXX",
        "..........XX..XXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXX.....",
        "..........XXXXXXXX..",
        "X........XXXXX......",
        "X.......XXXXXX......",
        "XX....XXXXXXXXXX....",
        "XXX..XXXXXXXXX.X....",
        "XXXXXXXXXXXXXX......",
        "XXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXX.......",
        "..XXXXXXXXXXX.......",
        "...XXXXXXXXX........",
        "....XXXXXXX.........",
        ".....XXX..XXX.......",
        ".....XX.............",
        ".....X..............",
    ])

    // RUN 2 — Chrome's second run frame (legs swap).
    static let rexRunB = PixelSprite([
        "...........XXXXXXXX.",
        "..........XXXXXXXXXX",
        "..........XX..XXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXX.....",
        "..........XXXXXXXX..",
        "X........XXXXX......",
        "X.......XXXXXX......",
        "XX....XXXXXXXXXX....",
        "XXX..XXXXXXXXX.X....",
        "XXXXXXXXXXXXXX......",
        "XXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXX.......",
        "..XXXXXXXXXXX.......",
        "...XXXXXXXXX........",
        "....XXXXXXX.........",
        ".....XX..XX.........",
        "......XX..X.........",
        "..........X.........",
    ])

    // SLEEP — eye closed as a 4-pixel horizontal slit ("—") at the same
    // row as the open-eye sprite. Wider than the open eye (4 px vs 2 px)
    // for two reasons:
    //   1. A horizontal line reads unambiguously as "closed / sleeping"
    //      where a small filled gap would just look like a smaller eye.
    //   2. At pixelSize<1 (compact pill renders at 0.75) anti-aliasing
    //      dilutes 1-2 px features into invisibility; 4 px survives.
    // Body geometry is identical to rexStand so waking transitions don't
    // shift any pixels — only the eye row changes.
    static let rexSleep = PixelSprite([
        "...........XXXXXXXX.",
        "..........XXXXXXXXXX",
        "..........XX....XXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXX.....",
        "..........XXXXXXXX..",
        "X........XXXXX......",
        "X.......XXXXXX......",
        "XX....XXXXXXXXXX....",
        "XXX..XXXXXXXXX.X....",
        "XXXXXXXXXXXXXX......",
        "XXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXX.......",
        "..XXXXXXXXXXX.......",
        "...XXXXXXXXX........",
        "....XXXXXXX.........",
        ".....XXX.XX.........",
        ".....XX...X.........",
        ".....X....X.........",
    ])

    // ACTION — Chrome's CRASHED frame. Eye is two adjacent gaps stacked
    // diagonally (the iconic x_x at 20×21 resolution). The view layer
    // tints the whole sprite red.
    static let rexAction = PixelSprite([
        "...........XXXXXXXX.",
        "..........XXXXXXXXXX",
        "..........XX..XXXXXX",
        "..........XX..XXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXX..",
        "X........XXXXX......",
        "X.......XXXXXX......",
        "XX....XXXXXXXXXX....",
        "XXX..XXXXXXXXX.X....",
        "XXXXXXXXXXXXXX......",
        "XXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXX.......",
        "..XXXXXXXXXXX.......",
        "...XXXXXXXXX........",
        "....XXXXXXX.........",
        ".....XXX.XX.........",
        ".....XX...X.........",
        ".....X....X.........",
    ])

    // EXPANDED — Chrome doesn't have a heroic pose; reuse the standing
    // frame. The renderer just shows it at a larger pixel scale.
    static let rexExpanded = PixelSprite([
        "...........XXXXXXXX.",
        "..........XXXXXXXXXX",
        "..........XX..XXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXXXXXXX",
        "..........XXXXX.....",
        "..........XXXXXXXX..",
        "X........XXXXX......",
        "X.......XXXXXX......",
        "XX....XXXXXXXXXX....",
        "XXX..XXXXXXXXX.X....",
        "XXXXXXXXXXXXXX......",
        "XXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXX.......",
        "..XXXXXXXXXXX.......",
        "...XXXXXXXXX........",
        "....XXXXXXX.........",
        ".....XXX.XX.........",
        ".....XX...X.........",
        ".....X....X.........",
    ])

    // MARK: - PLATE (Stegosaurus)

    static let plateStand = PixelSprite([
        "..........X.............",
        ".......X.X.X.X..........",
        "......X.X.X.X.X.........",
        ".....X.X.X.X.X.X........",
        "....XXXXXXXXXXXXX..XXXX.",
        "...XXXXXXXXXXXXXX.XX.XX.",
        "..XXXXXXXXXXXXXXXXXXXX..",
        ".XXXXXXXXXXXXXXXXXXXX...",
        "XXXXXXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXXXXX........",
        "..XXXXXXXXXXXX..........",
        "..XX.XX...XX.XX.........",
        "..XX.XX...XX.XX.........",
        "..XX.XX...XX.XX.........",
        "..XX.XX...XX.XX.........",
        ".XXX.XX...XX.XXX........",
    ])

    static let plateRunA = PixelSprite([
        "..........X.............",
        ".......X.X.X.X..........",
        "......X.X.X.X.X.........",
        ".....X.X.X.X.X.X........",
        "....XXXXXXXXXXXXX..XXXX.",
        "...XXXXXXXXXXXXXX.XX.XX.",
        "..XXXXXXXXXXXXXXXXXXXX..",
        ".XXXXXXXXXXXXXXXXXXXX...",
        "XXXXXXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXXXXX........",
        "..XXXXXXXXXXXX..........",
        "..XX.XX...XX.XX.........",
        "..XX.X....X.XXX.........",
        "..XX.X....X..XX.........",
        "..X.XX....X..X..........",
        ".XX..XX...XX..X.........",
    ])

    static let plateRunB = PixelSprite([
        "..........X.............",
        ".......X.X.X.X..........",
        "......X.X.X.X.X.........",
        ".....X.X.X.X.X.X........",
        "....XXXXXXXXXXXXX..XXXX.",
        "...XXXXXXXXXXXXXX.XX.XX.",
        "..XXXXXXXXXXXXXXXXXXXX..",
        ".XXXXXXXXXXXXXXXXXXXX...",
        "XXXXXXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXXXXX........",
        "..XXXXXXXXXXXX..........",
        "..XX.XX...XX.XX.........",
        "..XXXX....X.XX..........",
        "..XX.X....XX.X..........",
        "..X..X....XXX...........",
        ".XX..XX..XX..XX.........",
    ])

    // MARK: - TRI (Triceratops)

    static let triStand = PixelSprite([
        "........................",
        "...........XX...XX..X...",
        "..........XXXX.XXXX.X...",
        ".........XXXXXXXXXX.X...",
        "........XXXXXXXXXXXXX...",
        ".......XXXXXXXXXXXXXX...",
        "......XXXXXXXXXXXXXX....",
        ".XX..XXXXXXXXXXXXXX.....",
        "XXXXXXXXXXXXXXXXXXX.....",
        "XXXXXXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXXXXX........",
        "...XXX....XXX...........",
        "...XXX....XXX...........",
        "...X.X....X.X...........",
        "...X.X....X.X...........",
        "..XXXXX..XXXXX..........",
    ])

    static let triRunA = PixelSprite([
        "........................",
        "...........XX...XX..X...",
        "..........XXXX.XXXX.X...",
        ".........XXXXXXXXXX.X...",
        "........XXXXXXXXXXXXX...",
        ".......XXXXXXXXXXXXXX...",
        "......XXXXXXXXXXXXXX....",
        ".XX..XXXXXXXXXXXXXX.....",
        "XXXXXXXXXXXXXXXXXXX.....",
        "XXXXXXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXXXXX........",
        "...XX......XXX..........",
        "...X.......X.X..........",
        "..XX.......X.X..........",
        ".XX........X.X..........",
        "XXX.......XXXXX.........",
    ])

    static let triRunB = PixelSprite([
        "........................",
        "...........XX...XX..X...",
        "..........XXXX.XXXX.X...",
        ".........XXXXXXXXXX.X...",
        "........XXXXXXXXXXXXX...",
        ".......XXXXXXXXXXXXXX...",
        "......XXXXXXXXXXXXXX....",
        ".XX..XXXXXXXXXXXXXX.....",
        "XXXXXXXXXXXXXXXXXXX.....",
        "XXXXXXXXXXXXXXXXXX......",
        ".XXXXXXXXXXXXXXX........",
        "...XXX......XX..........",
        "...X.X.......XX.........",
        "...X.X........XX........",
        "...X.X.........XX.......",
        "..XXXXX.......XXX.......",
    ])

    // MARK: - SKY (Pterodactyl)

    static let skyStand = PixelSprite([
        "........................",
        "X.....................X.",
        "XX...................XX.",
        ".XX................XXX..",
        "..XXX............XXXXX..",
        "...XXX..........XXXXXX..",
        "....XXX........XXXXXXX..",
        ".....XXX......XXXX..XX..",
        "......XXX....XXXXXXXX...",
        ".......XX...XXXXXXXX....",
        "........XXXXXXXXXXX.....",
        ".........XXXXXXXX.......",
        "..........XX.XX.........",
        "...........X.X..........",
        "...........X.X..........",
        "...........X.X..........",
    ])

    static let skyRunA = PixelSprite([
        "..X..................X..",
        "..XX................XX..",
        "...XX..............XXX..",
        "....XX............XXXX..",
        ".....XXX........XXXXXX..",
        "......XXX......XXXXXXX..",
        ".......XX.....XXXX..XX..",
        ".......XX....XXXXXXXX...",
        ".......XX...XXXXXXXX....",
        "........XXXXXXXXXXX.....",
        ".........XXXXXXXX.......",
        "..........XX.XX.........",
        "...........X.X..........",
        "...........X.X..........",
        "...........X.X..........",
        "........................",
    ])

    static let skyRunB = PixelSprite([
        "........................",
        "........................",
        "X.....................X.",
        "XX...................XX.",
        ".XX................XXX..",
        "..XXX............XXXXX..",
        "...XXXX........XXXXXX...",
        "....XXXX......XXXXXX....",
        ".....XXXX....XXXX..XX...",
        "......XXXXXXXXXXXXXX....",
        "........XXXXXXXXXX......",
        "..........XX.XX.........",
        "...........X.X..........",
        "...........X.X..........",
        "...........X.X..........",
        "........................",
    ])

    // MARK: - LONG (Brontosaurus)

    static let longStand = PixelSprite([
        "..................XXXX..",
        "..................XX.X..",
        ".................XXXXX..",
        ".................XX.....",
        "................XX......",
        "...............XX.......",
        "..............XX........",
        "XX...........XX.........",
        ".XX.........XX..........",
        "..XXX......XX...........",
        "...XXXXXXXXXXXXXXXX.....",
        "..XXXXXXXXXXXXXXXXXX....",
        "....XXXXXXXXXXXXXX......",
        "....XXXX..XXXX..........",
        "....XXXX..XXXX..........",
        "...XXXXXX.XXXXXX........",
    ])

    static let longRunA = PixelSprite([
        "..................XXXX..",
        "..................XX.X..",
        ".................XXXXX..",
        ".................XX.....",
        "................XX......",
        "...............XX.......",
        "..............XX........",
        "XX...........XX.........",
        ".XX.........XX..........",
        "..XXX......XX...........",
        "...XXXXXXXXXXXXXXXX.....",
        "..XXXXXXXXXXXXXXXXXX....",
        "....XXXXXXXXXXXXXX......",
        "....XX.....XXXX.........",
        "....X......XXXX.........",
        "..XXX.....XXXXXX........",
    ])

    static let longRunB = PixelSprite([
        "..................XXXX..",
        "..................XX.X..",
        ".................XXXXX..",
        ".................XX.....",
        "................XX......",
        "...............XX.......",
        "..............XX........",
        "XX...........XX.........",
        ".XX.........XX..........",
        "..XXX......XX...........",
        "...XXXXXXXXXXXXXXXX.....",
        "..XXXXXXXXXXXXXXXXXX....",
        "....XXXXXXXXXXXXXX......",
        "....XXXX....XX..........",
        "....XXXX.....X..........",
        "...XXXXXX...XXX.........",
    ])

    // MARK: - CLAW (Velociraptor)

    static let clawStand = PixelSprite([
        "........................",
        "..................XXXX..",
        ".................XXXXXX.",
        ".................XX.XXX.",
        ".................XXXXXX.",
        "................XXXXX...",
        "..............XXXX......",
        ".............XXX........",
        "XX..........XXXX........",
        ".XXX.......XXXXXX.......",
        "..XXXXXXXXXXXXXXXXX.....",
        "..XXXXXXXXXXXXXXXXXXX...",
        "...XXXXXXXXXXXXXXXX.....",
        "....XXXXXXXXXXXX........",
        "......XX....XX..........",
        "X....XXXX..XXXX.........",
    ])

    static let clawRunA = PixelSprite([
        "........................",
        "..................XXXX..",
        ".................XXXXXX.",
        ".................XX.XXX.",
        ".................XXXXXX.",
        "................XXXXX...",
        "..............XXXX......",
        ".............XXX........",
        "XX..........XXXX........",
        ".XXX.......XXXXXX.......",
        "..XXXXXXXXXXXXXXXXX.....",
        "..XXXXXXXXXXXXXXXXXXX...",
        "...XXXXXXXXXXXXXXXX.....",
        "....XXXXXXXXXXXX........",
        "....XXX.......X.........",
        "XXX.X........XXXXX......",
    ])

    static let clawRunB = PixelSprite([
        "........................",
        "..................XXXX..",
        ".................XXXXXX.",
        ".................XX.XXX.",
        ".................XXXXXX.",
        "................XXXXX...",
        "..............XXXX......",
        ".............XXX........",
        "XX..........XXXX........",
        ".XXX.......XXXXXX.......",
        "..XXXXXXXXXXXXXXXXX.....",
        "..XXXXXXXXXXXXXXXXXXX...",
        "...XXXXXXXXXXXXXXXX.....",
        "....XXXXXXXXXXXX........",
        "......X.......XXX.......",
        "X....XXXX........XXX....",
    ])
}
