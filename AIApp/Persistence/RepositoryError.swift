import Foundation

/// Typed failures for anything that reads or writes the app's own files.
///
/// The point of naming these is that they are handled differently and must not
/// be collapsed into one `try?`: a missing file is normal on first launch,
/// unreadable data means the user's content is at risk and should be preserved
/// rather than overwritten, and a write failure must never be silent.
enum RepositoryError: LocalizedError, Equatable {
    /// Nothing stored yet — expected on first run, not a problem.
    case notFound
    /// The file exists but could not be decoded. The bytes are kept.
    case corrupt(path: String, underlying: String)
    /// Encoding or writing failed; the previous contents are untouched.
    case writeFailed(path: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Noch nichts gespeichert."
        case .corrupt(let path, _):
            return String(localized: "Gespeicherte Daten in \(path) sind unlesbar. Eine Kopie wurde beiseitegelegt.")
        case .writeFailed(let path, let underlying):
            return String(localized: "Konnte \(path) nicht speichern: \(underlying)")
        }
    }

    /// True when the caller should start from empty rather than surface an error.
    var isEmptyStart: Bool { self == .notFound }
}
