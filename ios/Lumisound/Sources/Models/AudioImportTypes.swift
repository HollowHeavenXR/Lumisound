import UniformTypeIdentifiers

/// Everything the music importers accept: any system "audio" type plus
/// the containers the Lumisound engine decodes that iOS doesn't file under
/// audio (Opus / WebM / Matroska / MP2 / locked `.lms`). Kept in step with
/// `import::SUPPORTED` in rust/core.
enum AudioImportTypes {
    static let all: [UTType] = {
        var types: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        for ext in ["opus", "ogg", "webm", "mka", "mp2", "mp1", "flac", "caf", "aac", "m4a", "m4v", "mov", "mp4", "lms"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) { types.append(t) }
        }
        return types
    }()
}
