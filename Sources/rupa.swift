import SwiftUI
import AppKit
import CoreText

// MARK: - Model

/// CSS-style weight classes, 1 = Thin … 9 = Black. 0 is the "Main" pseudo-class (each family's default face).
enum Weight {
    static let names = ["Main", "Thin", "ExtraLight", "Light", "Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Black"]

    // Order matters: compound names before the words they contain.
    static let styleWords: [(String, Int)] = [
        ("hairline", 1), ("thin", 1), ("extralight", 2), ("ultralight", 2), ("extra light", 2), ("ultra light", 2),
        ("light", 3), ("semibold", 6), ("demibold", 6), ("semi bold", 6), ("demi bold", 6), ("demi", 6),
        ("extrabold", 8), ("ultrabold", 8), ("extra bold", 8), ("ultra bold", 8), ("heavy", 8),
        ("black", 9), ("fat", 9), ("medium", 5), ("bold", 7),
        ("regular", 4), ("book", 4), ("roman", 4), ("normal", 4), ("plain", 4),
    ]
    // CoreText weight trait for each class (matches OS/2 usWeightClass 100…900).
    static let traitValues: [Double] = [-0.8, -0.6, -0.4, 0, 0.23, 0.3, 0.4, 0.56, 0.62]

    static func classify(style: String, trait: Double) -> Int {
        let s = style.lowercased()
        if let hit = styleWords.first(where: { s.contains($0.0) }) { return hit.1 }
        let i = traitValues.indices.min { abs(traitValues[$0] - trait) < abs(traitValues[$1] - trait) }!
        return i + 1
    }
}

struct Face: Identifiable, Hashable {
    let id: String      // PostScript name
    let style: String
    let weight: Int     // 1…9
    let italic: Bool
}

final class Family: Identifiable {
    let id: String      // family name
    let faces: [Face]   // Thin → Black, upright before italic
    let primary: Face
    lazy var charset: CFCharacterSet = CTFontCopyCharacterSet(CTFontCreateWithName(primary.id as CFString, 12, nil))

    init(id: String, faces: [Face], primary: Face) {
        self.id = id; self.faces = faces; self.primary = primary
    }

    /// Faces matching any selected weight class and slant. Weight 0 ("Main") means the family's
    /// default face, or its nearest italic when italic is selected.
    func faces(weights: Set<Int>, upright: Bool, italic: Bool) -> [Face] {
        var picked = Set<String>()
        if weights.contains(0) {
            if upright && (!primary.italic || !faces.contains { !$0.italic }) { picked.insert(primary.id) }
            if italic, let it = faces.filter(\.italic).min(by: {
                abs($0.weight - primary.weight) < abs($1.weight - primary.weight)
            }) { picked.insert(it.id) }
        }
        for f in faces where weights.contains(f.weight) && (f.italic ? italic : upright) {
            picked.insert(f.id)
        }
        return faces.filter { picked.contains($0.id) }
    }

    func covers(_ text: String) -> Bool {
        for s in text.unicodeScalars {
            if s.properties.isWhitespace || s.properties.generalCategory == .format { continue }
            if !CFCharacterSetIsLongCharacterMember(charset, s.value) { return false }
        }
        return true
    }
}

// MARK: - Scanning

enum Scanner {
    static let fontDirs = [
        "/System/Library/Fonts", "/Library/Fonts", NSHomeDirectory() + "/Library/Fonts",
        "/System/Library/AssetsV2/com_apple_MobileAsset_Font8",
    ]
    static let fontExts: Set<String> = ["ttf", "otf", "ttc", "otc", "dfont"]

    static func scan() -> [Family] {
        var byFamily: [String: [(ps: String, style: String)]] = [:]

        // Installed fonts, including named instances of variable fonts.
        let fm = NSFontManager.shared
        for name in CTFontManagerCopyAvailableFontFamilyNames() as! [String] {
            for m in fm.availableMembers(ofFontFamily: name) ?? [] {
                guard let ps = m.first as? String else { continue }
                byFamily[name, default: []].append((ps, (m.count > 1 ? m[1] as? String : nil) ?? ""))
            }
        }

        // macOS keeps many system fonts on disk but out of the available list (Font Book still
        // shows them). They load fine by PostScript name, so read their families from the files.
        let installed = Set(byFamily.keys)
        for dir in fontDirs {
            guard let e = FileManager.default.enumerator(atPath: dir) else { continue }
            for case let p as String in e where fontExts.contains((p as NSString).pathExtension.lowercased()) {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(p) as CFURL
                for d in (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor]) ?? [] {
                    guard let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String,
                          !installed.contains(family),
                          let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String else { continue }
                    byFamily[family, default: []].append((ps, CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? ""))
                }
            }
        }

        var out: [Family] = []
        for (name, members) in byFamily where !name.hasPrefix(".") {
            var seen = Set<String>()
            var faces: [(face: Face, trait: Double)] = []
            for m in members where seen.insert(m.ps).inserted {
                let traits = CTFontCopyTraits(CTFontCreateWithName(m.ps as CFString, 12, nil)) as? [CFString: Any] ?? [:]
                let trait = (traits[kCTFontWeightTrait] as? Double) ?? 0
                let sym = (traits[kCTFontSymbolicTrait] as? UInt32) ?? 0
                let lower = m.style.lowercased()
                let italic = sym & CTFontSymbolicTraits.traitItalic.rawValue != 0
                    || lower.contains("italic") || lower.contains("oblique")
                faces.append((Face(id: m.ps, style: m.style, weight: Weight.classify(style: m.style, trait: trait),
                                   italic: italic), trait))
            }
            guard !faces.isEmpty else { continue }
            faces.sort { ($0.face.weight, $0.face.italic ? 1 : 0, $0.trait) < ($1.face.weight, $1.face.italic ? 1 : 0, $1.trait) }
            let main = faces.first { $0.face.weight == 4 && !$0.face.italic }
                ?? faces.filter { !$0.face.italic }.min { abs($0.trait) < abs($1.trait) }
                ?? faces.min { abs($0.trait) < abs($1.trait) }!
            out.append(Family(id: name, faces: faces.map(\.face), primary: main.face))
        }
        return out.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }
}

// MARK: - Store

enum Mode: String, CaseIterable, Identifiable {
    case all = "All", favs = "Favourites", hidden = "Hidden"
    var id: String { rawValue }
}

@Observable
final class Store {
    var families: [Family] = []
    var loading = true
    var favs: Set<String> { didSet { save(favs, "favs") } }
    var hidden: Set<String> { didSet { save(hidden, "hidden") } }

    init() {
        let d = UserDefaults.standard
        favs = Set(d.stringArray(forKey: "favs") ?? [])
        hidden = Set(d.stringArray(forKey: "hidden") ?? [])
        Task.detached {
            let f = Scanner.scan()
            await MainActor.run { self.families = f; self.loading = false }
        }
    }

    private func save(_ s: Set<String>, _ key: String) {
        UserDefaults.standard.set(s.sorted(), forKey: key)
    }

    func list(_ mode: Mode) -> [Family] {
        switch mode {
        case .all: families.filter { !hidden.contains($0.id) }
        case .favs: families.filter { favs.contains($0.id) }
        case .hidden: families.filter { hidden.contains($0.id) }
        }
    }

    static func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }
}

// MARK: - Views

@main
struct RupaApp: App {
    @State private var store = Store()

    init() {
        // `rupa --dump` prints every face as family, style, weight class, italic; then exits.
        if CommandLine.arguments.contains("--dump") {
            for f in Scanner.scan() {
                for x in f.faces {
                    print("\(f.id)\t\(x.style)\t\(Weight.names[x.weight])\(x.italic ? "\titalic" : "")\(x == f.primary ? "\tMAIN" : "")")
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        Window("rūpa", id: "main") {
            ContentView(store: store).frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 820)
    }
}

struct ContentView: View {
    @Bindable var store: Store
    @AppStorage("sample") private var sample = "rūpa — The quick brown fox jumps over the lazy dog 0123456789"
    @AppStorage("size") private var size = 36.0
    @AppStorage("mode") private var mode: Mode = .all
    @AppStorage("weights") private var weightsRaw = "0"
    @AppStorage("upright") private var upright = true
    @AppStorage("italic") private var italic = false
    @State private var search = ""

    private var weights: Set<Int> { Set(weightsRaw.split(separator: ",").compactMap { Int($0) }) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.loading {
                ProgressView("Reading fonts…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rows = visible
                if rows.isEmpty {
                    Text(mode == .favs ? "No favourites yet. Star a font to add it." : "Nothing matches these styles.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows, id: \.0.id) { family, faces in
                                FamilyHeader(store: store, family: family, sample: sample)
                                ForEach(faces) { face in
                                    FaceRow(face: face, sample: sample.isEmpty ? family.id : sample, size: size)
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Families with at least one face matching the style chips, paired with those faces.
    private var visible: [(Family, [Face])] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let w = weights
        return store.list(mode).compactMap { f in
            guard q.isEmpty || f.id.localizedCaseInsensitiveContains(q) else { return nil }
            let faces = f.faces(weights: w, upright: upright, italic: italic)
            return faces.isEmpty ? nil : (f, faces)
        }
    }

    private func toggleWeight(_ i: Int) {
        var w = weights
        if w.contains(i) { if w.count > 1 { w.remove(i) } } else { w.insert(i) }
        weightsRaw = w.sorted().map(String.init).joined(separator: ",")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Type something to preview…", text: $sample, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title2)
                .lineLimit(1...4)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            HStack(spacing: 16) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { m in Text("\(m.rawValue) \(store.list(m).count)").tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Filter by name", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Spacer()
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                Slider(value: $size, in: 10...160).frame(width: 180)
                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                Text("\(Int(size))").monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
            }
            HStack(spacing: 6) {
                ForEach(Weight.names.indices, id: \.self) { i in
                    Chip(label: Weight.names[i], on: weights.contains(i)) { toggleWeight(i) }
                        .help(i == 0 ? "Each family's default face" : "Faces in the \(Weight.names[i]) weight class")
                    if i == 0 { Divider().frame(height: 16).padding(.horizontal, 4) }
                }
                Divider().frame(height: 16).padding(.horizontal, 4)
                Chip(label: "Upright", on: upright) { if italic || !upright { upright.toggle() } }
                Chip(label: "Italic", on: italic) { if upright || !italic { italic.toggle() } }
                Spacer()
                Button("All") { weightsRaw = (1...9).map(String.init).joined(separator: ","); upright = true; italic = true }
                    .buttonStyle(.borderless)
                Button("Reset") { weightsRaw = "0"; upright = true; italic = false }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
    }
}

struct Chip: View {
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct FamilyHeader: View {
    let store: Store
    let family: Family
    let sample: String
    @State private var hovering = false

    var body: some View {
        let fav = store.favs.contains(family.id)
        let hidden = store.hidden.contains(family.id)
        HStack(spacing: 8) {
            Text(family.id).font(.headline)
            Text("\(family.faces.count) style\(family.faces.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            if !sample.isEmpty && !family.covers(sample) {
                Text("missing glyphs").font(.caption2).foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().stroke(Color.orange.opacity(0.5)))
            }
            Spacer()
            Group {
                iconButton("doc.on.doc", "Copy family name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(family.id, forType: .string)
                }
                iconButton(hidden ? "eye" : "eye.slash", hidden ? "Unhide" : "Hide") {
                    Store.toggle(&store.hidden, family.id)
                }
            }
            .opacity(hovering ? 1 : 0.3)
            iconButton(fav ? "star.fill" : "star", fav ? "Remove from favourites" : "Add to favourites") {
                Store.toggle(&store.favs, family.id)
            }
            .foregroundStyle(fav ? Color.yellow : Color.secondary)
            .opacity(fav || hovering ? 1 : 0.3)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 2)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 20, height: 20) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

struct FaceRow: View {
    let face: Face
    let sample: String
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(face.style).font(.caption).foregroundStyle(.tertiary).help(face.id)
            Text(sample)
                .font(Font(CTFontCreateWithName(face.id as CFString, size, nil)))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
