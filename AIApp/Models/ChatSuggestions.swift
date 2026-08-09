import Foundation

/// The chat empty-state chips: a curated pool of mini-app ideas plus the
/// seeded sampler that picks which of them a given conversation shows.
///
/// Why seeded and not `shuffled()`: the empty state is rendered inside
/// `ChatView.body`, which recomputes on every keyboard focus change, busy
/// toggle and scroll update. A plain shuffle in the view would visibly
/// re-deal the chips while the user is looking at them. The sample is
/// therefore computed ONCE per thread activation (see
/// `ChatSession.refreshEmptyStateSuggestions`) from a seed derived from the
/// thread id — stable for that conversation, different for the next one, and
/// deterministic enough to unit-test with an injected seed.
enum ChatSuggestions {

    /// Chips shown at once (the horizontal row scrolls, but four is what fits).
    static let slotCount = 4

    /// How many of the slots model-generated ideas may ever occupy. The rest
    /// stays curated, so a provider that answers with nonsense — or with the
    /// same three ideas all day — can never take over the whole surface.
    static let maxModelSuggestions = 3

    /// Curated German mini-app ideas. Deliberately short (the chip is
    /// `lineLimit(1)`) and mostly offline-capable: an idea that needs the
    /// network sends a brand-new user straight into the mini-app network
    /// consent prompt, so only a couple of those are in here.
    static let buildPool: [String] = [
        String(localized: "Trinkgeld-Rechner"),
        String(localized: "Todo-Liste"),
        String(localized: "Pomodoro-Timer"),
        String(localized: "Tech-News heute"),
        String(localized: "Einkaufsliste"),
        String(localized: "Haushaltsbuch"),
        String(localized: "Wasser-Tracker"),
        String(localized: "Einheiten-Umrechner"),
        String(localized: "Vokabel-Trainer"),
        String(localized: "Countdown-Timer"),
        String(localized: "Würfel-Simulator"),
        String(localized: "Notizzettel"),
        String(localized: "QR-Code-Generator"),
        String(localized: "BMI-Rechner"),
        String(localized: "Zitat des Tages"),
        String(localized: "Gewohnheits-Tracker"),
        String(localized: "Zufalls-Entscheider"),
        String(localized: "Rechnung teilen"),
    ]

    // MARK: - Seeded RNG

    /// SplitMix64 — a few lines, no dependency, and the same sequence on every
    /// platform and run, which is the whole point: tests pin a seed and get a
    /// known set back.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Folds the 16 UUID bytes into one seed, so a conversation keeps its
    /// chips for as long as it exists — including across app launches.
    static func seed(for threadId: UUID) -> UInt64 {
        var seed: UInt64 = 0xCBF2_9CE4_8422_2325   // FNV-1a offset basis
        withUnsafeBytes(of: threadId.uuid) { bytes in
            for byte in bytes {
                seed = (seed ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
        }
        return seed
    }

    // MARK: - Sampling

    /// Comparison key for "the same idea": case- and punctuation-insensitive,
    /// so "Todo-Liste" and "todo liste" never share the row.
    static func normalizedKey(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// `count` distinct ideas from `pool`, deterministic for a given seed.
    ///
    /// `previous` is a SOFT exclusion: it is dropped when honoring it would
    /// leave too few candidates, because showing a repeat beats showing three
    /// chips (or none).
    static func sample(
        count: Int = slotCount,
        seed: UInt64,
        excluding previous: Set<String> = [],
        from pool: [String] = buildPool
    ) -> [String] {
        guard count > 0 else { return [] }
        let blocked = Set(previous.map(normalizedKey))
        var candidates = pool.filter { !blocked.contains(normalizedKey($0)) }
        if candidates.count < count { candidates = pool }
        var rng = SeededGenerator(seed: seed)
        return Array(candidates.shuffled(using: &rng).prefix(count))
    }

    /// The single composition rule for the empty-state row: up to
    /// `maxModelSuggestions` model-generated ideas take the leading slots, the
    /// curated pool fills the rest — never repeating an idea the model already
    /// proposed, and preferring ideas the previous conversation did not show.
    ///
    /// Everything that wants to influence the chips goes through here; the
    /// view only ever reads the result.
    static func compose(
        modelSuggestions: [String] = [],
        count: Int = slotCount,
        seed: UInt64,
        excluding previous: Set<String> = [],
        from pool: [String] = buildPool
    ) -> [String] {
        var seen = Set<String>()
        var lead: [String] = []
        for raw in modelSuggestions {
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedKey(item)
            guard !item.isEmpty, !key.isEmpty, seen.insert(key).inserted else { continue }
            lead.append(item)
            if lead.count >= min(maxModelSuggestions, count) { break }
        }
        guard lead.count < count else { return lead }

        // Hard-filter the pool by the model items BEFORE sampling: `sample`
        // may drop its soft exclusion set, and a near-duplicate of a model
        // idea sitting next to it in the same row is exactly what this rule
        // exists to prevent.
        let padPool = pool.filter { !seen.contains(normalizedKey($0)) }
        let pad = sample(count: count - lead.count, seed: seed, excluding: previous, from: padPool)
        var result = lead
        for item in pad where seen.insert(normalizedKey(item)).inserted {
            result.append(item)
        }
        return result
    }
}
