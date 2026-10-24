// Derived from MijiCLI; frozen upstream provenance is recorded in UPSTREAM.md.
import Foundation
import MijiCore

// Keep the wire contract used by IsolatedContentExtractor: extract --file PATH.
// This helper emits ExtractedContent JSON; the embedding host owns all index writes.
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 3, args[0] == "extract", args[1] == "--file", !args[2].isEmpty else {
        throw NSError(domain: "MijiExtract", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "用法：miji-extract extract --file FILE"
        ])
    }
    let content = try ContentExtractor.extract(url: URL(fileURLWithPath: args[2]))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(content))
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
