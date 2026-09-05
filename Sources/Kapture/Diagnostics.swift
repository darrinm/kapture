// Command-line harnesses. These run instead of the app — no NSApplication, no windows — so
// they work with the display locked, unlike the UI-driven scripts. main.swift dispatches to
// them; each one exits the process when it is done.
import Foundation
import KaptureCore
import KaptureIntelligence

enum Diagnostics {
    /// Ingest smoke mode (scripts/test-ingest.command). `--dry-run` previews the name each
    /// capture would get without touching a file; otherwise every capture is enqueued with no
    /// debounce and the run reports how much text got indexed.
    static func runIngestNow() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: harness output survives a timeout
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                // exclusive: refuses to run beside the app rather than sweep its in-flight
                // uploads out of .pending or race its operation lock from another process
                let library = try Library(db: KaptureCore.Database(), exclusive: true)
                await IngestQueue.shared.configure(library: library)
                let useAPI = CommandLine.arguments.contains("--api")
                if CommandLine.arguments.contains("--dry-run") {
                    await previewNames(library: library, useAPI: useAPI)
                    sem.signal(); return
                }
                let ids = library.search("", scope: .all).map(\.id)
                for id in ids { await IngestQueue.shared.enqueue(id, after: 0) }
                print("enqueued \(ids.count) captures; indexing…")
                try? await Task.sleep(for: .seconds(Double(min(90, 8 + ids.count * 2))))
                let indexed = library.indexedCount()
                print("indexed: \(indexed)/\(ids.count)")
                if let sample = library.sampleIndexedText() {
                    print("sample: \(sample)")
                    let term = sample.split(separator: " ").first(where: { $0.count > 3 }).map(String.init) ?? "zzz"
                    print("search '\(term)' hits: \(library.search(term).count)")
                }
            } catch { print("ingest-now failed: \(error)") }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }

    /// Show what naming WOULD produce, without touching any file. Goes through the same
    /// `NamingService.best` ladder the ingest queue uses, so a preview can't advertise a name
    /// the app would never pick.
    private static func previewNames(library: Library, useAPI: Bool) async {
        // The harness prefers an env key: a Keychain read blocks on a permission prompt that
        // can't be answered with the display locked, and it is only touched when the API engine
        // is actually being exercised. The app itself always uses the Keychain.
        let key = useAPI
            ? (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? Keychain.anthropicKey)
            : nil
        if useAPI && key == nil { print("no Anthropic key in the Keychain"); return }

        var records = library.search("", scope: .all)
        if let i = CommandLine.arguments.firstIndex(of: "--limit"),
           CommandLine.arguments.count > i + 1, let n = Int(CommandLine.arguments[i + 1]) {
            records = Array(records.prefix(n))
        }
        for r in records {
            let ocr = library.ocrText(r.id) ?? ""
            let old = (r.relPath as NSString).lastPathComponent
            // only decode when the API engine will actually use the pixels
            var jpeg: Data?
            if key != nil {
                guard let image = OverlayPosterDecoder.decode(library.url(for: r)) else {
                    print("\(old) → (undecodable)"); continue
                }
                jpeg = ImageEncoding.jpegData(image)
            }
            guard let (naming, engine) = await NamingService.best(jpeg: jpeg, ocr: ocr,
                                                                  record: r, key: key) else {
                print("\(old) → (no name)"); continue
            }
            print("\(old) → \(naming.filename)  [\(engine.rawValue)] "
                  + "tags=\(naming.tags.joined(separator: ",")) — \(naming.summary)")
        }
    }
}
