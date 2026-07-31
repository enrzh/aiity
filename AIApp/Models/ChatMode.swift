import Foundation

/// How much latitude the agent has before it acts.
///
/// The distinction is about *irreversibility*, not capability: searching the
/// web is cheap and undoable, but building and keeping things, spending tokens
/// on long tool chains, or acting on a half-understood request are not. The
/// mode says how much of that the user wants to see coming.
enum ChatMode: String, CaseIterable, Identifiable, Codable {
    /// Think first, act after the user agrees. The agent lays out what it
    /// intends to do and waits.
    case approval
    /// Plan only — never uses tools, never builds. For thinking a problem
    /// through before committing to anything.
    case plan
    /// Keep going until the thing is actually built: after each attempt the
    /// mini-app is validated and, if it still has structural problems, the
    /// agent is sent straight back in to fix them — without the user having to
    /// say "continue" each round.
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approval: return "Nachfragen"
        case .plan: return "Nur planen"
        case .auto: return "Automatisch"
        }
    }

    var systemImage: String {
        switch self {
        case .approval: return "hand.raised"
        case .plan: return "list.bullet.rectangle"
        case .auto: return "bolt"
        }
    }

    var detail: String {
        switch self {
        case .approval: return "Sagt erst, was es vorhat, und wartet auf dein OK."
        case .plan: return "Denkt nur mit — nutzt keine Tools und baut nichts."
        case .auto: return "Arbeitet durch, bis die App steht."
        }
    }

    /// How many validate → fix rounds the agent gets after producing a
    /// mini-app that still has structural problems.
    ///
    /// One is the old behaviour and stays for the modes where the user is
    /// meant to stay in the loop. Auto keeps going, because "always approve"
    /// means "don't stop to ask me, finish it" — but it is still BOUNDED: an
    /// unbounded repair loop against a model that cannot fix the issue is an
    /// unbounded bill.
    var maxRepairPasses: Int {
        switch self {
        case .auto: return 4
        case .approval, .plan: return 1
        }
    }

    /// Group rounds the agents run on their own before handing back.
    ///
    /// Auto continues by itself — that is what "don't stop to ask me" means for
    /// a discussion. The others hand back after one round so the user decides
    /// whether it is worth another. Bounded in every mode: a conversation that
    /// never yields is a bill that never stops.
    var automaticGroupRounds: Int {
        switch self {
        case .auto: return 3
        case .approval, .plan: return 1
        }
    }

    /// Whether the UI should offer a manual "keep talking" affordance. In auto
    /// it would be redundant — the group already continues on its own.
    var showsContinueDiscussion: Bool { self != .auto }

    /// Whether a repair round should run even for a substantial document.
    /// Outside auto, only an obviously-truncated app is auto-repaired; auto
    /// fixes real apps too, which is the point of it.
    var repairsCompleteApps: Bool { self == .auto }

    /// Whether the agent may call tools at all in this mode.
    ///
    /// Plan mode withholds them outright rather than asking the model not to
    /// use them: a prompt is a request, an empty tool list is a guarantee.
    var allowsTools: Bool { self != .plan }

    /// Appended to the system prompt.
    var instructions: String {
        switch self {
        case .auto:
            return ""
        case .approval:
            return """

            # Modus: Nachfragen
            Bevor du Tools benutzt, eine Mini-App baust oder etwas Aufwendiges startest: \
            beschreibe in zwei bis drei Sätzen, was du vorhast und warum, und frag, ob du loslegen sollst. \
            Warte auf ein Ja. Reine Antworten, Erklärungen und Rückfragen brauchen keine Freigabe — \
            frag nicht für Dinge, die du einfach beantworten kannst.
            """
        case .plan:
            return """

            # Modus: Nur planen
            Du hast in diesem Modus KEINE Tools und baust nichts. Erarbeite stattdessen einen Plan: \
            was zu tun ist, in welcher Reihenfolge, was vorher geklärt werden muss und woran es scheitern könnte. \
            Sag ausdrücklich, wenn du etwas nicht ohne Recherche beantworten kannst, statt zu raten. \
            Wenn der Nutzer die Umsetzung will, weise auf den Moduswechsel hin.
            """
        }
    }
}
