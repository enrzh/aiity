import Foundation

/// Tools over the documents the user handed to the agent in this session.
///
/// There is no `open_file(path:)` here, and that is the whole design: the model
/// addresses files by the NAME it was shown, resolved against
/// `UserFileAccess`. A path the model invents resolves to nothing. The app
/// container, the SwiftData store, the Keychain-backed provider keys and the
/// chat archive are simply not reachable through this surface.
struct ListUserFilesTool: AgentTool {
    let files: UserFileProviding

    static let name = PersonalToolPolicy.listFiles

    var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "List the documents the user shared with you in this session. These are the ONLY files you can read or write.",
            parameters: ["type": "object", "properties": [:], "required": []]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        let names = await files.fileNames()
        guard !names.isEmpty else {
            return ToolRunResult(String(localized: "Der Nutzer hat keine Dateien freigegeben."))
        }
        return ToolRunResult(names.map { "- \($0)" }.joined(separator: "\n"))
    }
}

struct ReadUserFileTool: AgentTool {
    let files: UserFileProviding
    let latch: ToolAttemptLatch

    static let name = PersonalToolPolicy.readFile

    var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "Read the text of one document the user shared. Use the exact name from list_user_files. Truncated at \(PersonalToolLimits.maxFileCharacters) characters.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "File name as shown by list_user_files"],
                ],
                "required": ["name"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        guard !latch.isExhausted(Self.name) else { return PersonalToolReply.exhausted(Self.name) }
        guard let name = stringArgument(toolArguments(argumentsJSON)["name"]) else {
            latch.record(Self.name)
            return PersonalToolReply.badArgument("name is required")
        }
        do {
            let text = try await files.read(named: name)
            return ToolRunResult("\(name):\n\(text)")
        } catch {
            latch.record(Self.name)
            return ToolRunResult(String(localized: "Datei konnte nicht gelesen werden: \(error.localizedDescription)"))
        }
    }
}

/// Overwrites a document the user picked — the only write this app performs on
/// a file outside its own container, and it is gated twice: the file must
/// already be in the picked set, and the user must confirm the exact name and
/// size in a sheet.
struct WriteUserFileTool: AgentTool {
    let files: UserFileProviding
    let confirmer: ToolConfirming
    let latch: ToolAttemptLatch

    static let name = PersonalToolPolicy.writeFile

    var spec: ToolSpec {
        ToolSpec(
            name: Self.name,
            description: "Overwrite one document the user shared with new text. The user must confirm first. Only names from list_user_files work; new files cannot be created.",
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "File name as shown by list_user_files"],
                    "content": ["type": "string", "description": "The complete new content of the file"],
                ],
                "required": ["name", "content"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        guard !latch.isExhausted(Self.name) else { return PersonalToolReply.exhausted(Self.name) }
        let args = toolArguments(argumentsJSON)
        guard let name = stringArgument(args["name"]) else {
            latch.record(Self.name)
            return PersonalToolReply.badArgument("name is required")
        }
        guard let content = args["content"] as? String else {
            latch.record(Self.name)
            return PersonalToolReply.badArgument("content is required")
        }
        // Refuse a name the user never picked BEFORE showing a sheet: a
        // confirmation dialog for a file that cannot be written is just a way
        // to train the user to tap "Erlauben".
        let known = await files.fileNames()
        guard known.contains(where: { $0.compare(name, options: .caseInsensitive) == .orderedSame }) else {
            latch.record(Self.name)
            return ToolRunResult(String(localized: "„\(name)“ ist nicht freigegeben. Verfügbar: \(known.joined(separator: ", ")). Neue Dateien kannst du nicht anlegen."))
        }
        let confirmed = await confirmer.confirm(ToolConfirmationRequest(
            title: String(localized: "Datei überschreiben?"),
            lines: [
                String(localized: "Datei: \(name)"),
                String(localized: "Neuer Inhalt: \(content.count) Zeichen"),
                String(localized: "Der bisherige Inhalt geht dabei verloren."),
            ],
            confirmTitle: String(localized: "Überschreiben"),
            isDestructive: true
        ))
        guard confirmed else {
            latch.exhaust(Self.name)
            return PersonalToolReply.declined(Self.name)
        }
        do {
            try await files.write(content, named: name)
            return ToolRunResult(String(localized: "„\(name)“ wurde überschrieben (\(content.count) Zeichen)."))
        } catch {
            latch.record(Self.name)
            return PersonalToolReply.blocked(
                String(localized: "Datei konnte nicht geschrieben werden: \(error.localizedDescription)"),
                tool: Self.name
            )
        }
    }
}
