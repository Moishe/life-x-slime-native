import Foundation

// Organism tracking, ported from life-ambient's tracker/cluster.ts (and its
// geometry.ts). Grouping and identity rules, including deterministic
// tie-breaks, are unchanged; only the data structures differ (flat grids
// instead of hash maps, for speed on large boards).

func cellRadial(_ x: Double, _ y: Double, width: Int, height: Int) -> Double {
    let cx = Double(width - 1) / 2
    let cy = Double(height - 1) / 2
    let maxDist = hypot(cx, cy)
    return min(1, hypot(x - cx, y - cy) / maxDist)
}

func panFromX(_ x: Double, width: Int) -> Double {
    x / Double(width - 1) * 2 - 1
}

private struct UnionFind {
    private var parent: [Int]

    init(_ n: Int) {
        parent = Array(0..<n)
    }

    mutating func find(_ i: Int) -> Int {
        var i = i
        while parent[i] != i {
            parent[i] = parent[parent[i]]
            i = parent[i]
        }
        return i
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a)
        let rb = find(b)
        if ra != rb { parent[ra] = rb }
    }
}

// Forward half of the 5x5 Chebyshev-distance-2 neighborhood.
private let forwardOffsets: [(Int, Int)] = {
    var offsets: [(Int, Int)] = []
    for dy in 0...2 {
        for dx in -2...2 where dy > 0 || dx > 0 { offsets.append((dx, dy)) }
    }
    return offsets
}()

/// Groups cells within Chebyshev distance 2 of each other. Groups come out in
/// the order of their first cell in `cells`.
func groupCells(_ cells: [Cell]) -> [[Cell]] {
    guard let first = cells.first else { return [] }
    var (minX, maxX, minY, maxY) = (first.x, first.x, first.y, first.y)
    for c in cells {
        minX = min(minX, c.x); maxX = max(maxX, c.x)
        minY = min(minY, c.y); maxY = max(maxY, c.y)
    }
    // Index of each cell on a padded grid over the cells' bounding box (-1 = empty).
    let w = maxX - minX + 1 + 2
    let h = maxY - minY + 1 + 2
    var index = [Int32](repeating: -1, count: w * h)
    func slot(_ x: Int, _ y: Int) -> Int? {
        let gx = x - minX
        let gy = y - minY
        guard gx >= 0, gy >= 0, gx < w, gy < h else { return nil }
        return gy * w + gx
    }
    for (i, c) in cells.enumerated() { index[slot(c.x, c.y)!] = Int32(i) }

    var uf = UnionFind(cells.count)
    for (i, c) in cells.enumerated() {
        for (dx, dy) in forwardOffsets {
            if let s = slot(c.x + dx, c.y + dy), index[s] >= 0 { uf.union(i, Int(index[s])) }
        }
    }
    var groupOfRoot = [Int](repeating: -1, count: cells.count)
    var groups: [[Cell]] = []
    for (i, c) in cells.enumerated() {
        let root = uf.find(i)
        if groupOfRoot[root] < 0 {
            groupOfRoot[root] = groups.count
            groups.append([])
        }
        groups[groupOfRoot[root]].append(c)
    }
    return groups
}

struct Point: Equatable {
    var x: Double
    var y: Double
}

struct ClusterMetrics {
    var id: Int
    var cells: [Cell]
    var cellCount: Int
    var centroid: Point
    var radial: Double
    var pan: Double
    var aspect: Double
    var delta: Int
    var velocity: Double
}

struct ClusterEvents {
    var born: [ClusterMetrics] = []
    var updated: [ClusterMetrics] = []
    var died: [Int] = []
}

private struct PrevCluster {
    var cells: [Cell]
    var centroid: Point
}

private func centroidOf(_ cells: [Cell]) -> Point {
    var sx = 0
    var sy = 0
    for c in cells {
        sx += c.x
        sy += c.y
    }
    return Point(x: Double(sx) / Double(cells.count), y: Double(sy) / Double(cells.count))
}

/// Groups live cells into organisms and keeps their ids stable across ticks.
final class ClusterTracker {
    private let width: Int
    private let height: Int
    private var nextId = 1
    // Previous clusters by id, plus their ids in insertion order.
    private var prev: [Int: PrevCluster] = [:]
    private var prevOrder: [Int] = []
    // Scratch: which previous cluster owned each cell (0 = none).
    private var owner: [Int32]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        owner = [Int32](repeating: 0, count: width * height)
    }

    func update(_ liveCells: [Cell]) -> ClusterEvents {
        struct Group {
            var cells: [Cell]
            var centroid: Point
            var claim: Int?
        }
        var groups = groupCells(liveCells).map { Group(cells: $0, centroid: centroidOf($0), claim: nil) }

        // 1. Claim by largest cell overlap (ties toward lower prev id).
        setOwners(to: { Int32($0) })
        for g in groups.indices {
            var overlaps: [Int: Int] = [:]
            for c in groups[g].cells {
                let id = ownerOf(c)
                if id != 0 { overlaps[id, default: 0] += 1 }
            }
            var best: (id: Int, overlap: Int)?
            for (id, overlap) in overlaps {
                if let b = best, !(overlap > b.overlap || (overlap == b.overlap && id < b.id)) { continue }
                best = (id, overlap)
            }
            groups[g].claim = best?.id
        }
        setOwners(to: { _ in 0 })

        // 2. Fallback: an unclaimed group adopts the nearest unclaimed prev centroid within 3.
        var claimed = Set(groups.compactMap(\.claim))
        for g in groups.indices where groups[g].claim == nil {
            var best: (id: Int, d: Double)?
            for id in prevOrder where !claimed.contains(id) {
                let p = prev[id]!.centroid
                let d = hypot(groups[g].centroid.x - p.x, groups[g].centroid.y - p.y)
                guard d <= 3 else { continue }
                if let b = best, !(d < b.d || (d == b.d && id < b.id)) { continue }
                best = (id, d)
            }
            if let best {
                groups[g].claim = best.id
                claimed.insert(best.id)
            }
        }

        // 3. Splits: several groups claiming one prev id -> the largest keeps it
        // (the earliest group among equals).
        var claimants: [Int: [Int]] = [:]
        for g in groups.indices {
            if let claim = groups[g].claim { claimants[claim, default: []].append(g) }
        }
        for (_, list) in claimants where list.count > 1 {
            var winner = list[0]
            for g in list.dropFirst() where groups[g].cells.count > groups[winner].cells.count { winner = g }
            for g in list where g != winner { groups[g].claim = nil }
        }

        // 4. Build events.
        var events = ClusterEvents()
        var claimedIds = Set<Int>()
        var nextPrev: [Int: PrevCluster] = [:]
        var nextOrder: [Int] = []
        for g in groups {
            let id: Int
            if let claim = g.claim {
                id = claim
                claimedIds.insert(id)
            } else {
                id = nextId
                nextId += 1
            }
            let m = metrics(id: id, cells: g.cells, centroid: g.centroid, prev: g.claim.flatMap { prev[$0] })
            if g.claim == nil { events.born.append(m) } else { events.updated.append(m) }
            nextPrev[id] = PrevCluster(cells: g.cells, centroid: g.centroid)
            nextOrder.append(id)
        }
        events.died = prevOrder.filter { !claimedIds.contains($0) }
        prev = nextPrev
        prevOrder = nextOrder
        return events
    }

    private func setOwners(to value: (Int) -> Int32) {
        for id in prevOrder {
            let v = value(id)
            for c in prev[id]!.cells where inBoard(c) { owner[c.y * width + c.x] = v }
        }
    }

    private func ownerOf(_ c: Cell) -> Int {
        inBoard(c) ? Int(owner[c.y * width + c.x]) : 0
    }

    private func inBoard(_ c: Cell) -> Bool {
        c.x >= 0 && c.y >= 0 && c.x < width && c.y < height
    }

    private func metrics(id: Int, cells: [Cell], centroid: Point, prev: PrevCluster?) -> ClusterMetrics {
        var (minX, maxX, minY, maxY) = (Int.max, Int.min, Int.max, Int.min)
        for c in cells {
            minX = min(minX, c.x); maxX = max(maxX, c.x)
            minY = min(minY, c.y); maxY = max(maxY, c.y)
        }
        return ClusterMetrics(
            id: id,
            cells: cells,
            cellCount: cells.count,
            centroid: centroid,
            radial: cellRadial(centroid.x, centroid.y, width: width, height: height),
            pan: panFromX(centroid.x, width: width),
            aspect: Double(maxX - minX + 1) / Double(maxY - minY + 1),
            delta: prev.map { cells.count - $0.cells.count } ?? 0,
            velocity: prev.map { hypot(centroid.x - $0.centroid.x, centroid.y - $0.centroid.y) } ?? 0
        )
    }
}
