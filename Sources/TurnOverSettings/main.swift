// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver Settings (18 Oct 2026): TurnOver's settings in an ordinary window, sections down the side, ordinary
// controls. It lives inside TurnOver.app and is read by TurnOver like any app. It never writes the settings file:
// each change goes to TurnOver as a patch (SettingsBridge), and TurnOver answers with the settings as they now are.
// Through TurnOver's control channel, which only programs signed by TurnOver's developer may use (TurnOverControl).
import SwiftUI
import AVFoundation
import TurnOverControl

@MainActor
final class Model: ObservableObject {
    @Published var state: [String: Any] = [:]
    @Published var connected = false
    /// The section shown. Kept here rather than in a @State: State is a macro in the macOS 27 SDK, and its plugin
    /// comes only with Xcode, so the Command Line Tools could not build this app (21 Oct 2026).
    @Published var pane: Pane? = .speech
    private var connection: ControlClient.Connection?

    init() {
        connect()
    }

    /// Connected to TurnOver and listening for its settings; tried again every two seconds until TurnOver is there,
    /// and again if TurnOver restarts.
    private func connect() {
        connection = ControlClient.Connection(received: { [weak self] message in
            guard message["op"] as? String == "state", let json = message["json"] as? String, let data = json.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            self?.state = dict; self?.connected = true
        }, ended: { [weak self] in
            self?.connected = false; self?.connection = nil
            self?.retry()
        })
        if let connection { connection.send(["op": "subscribe"]) } else { retry() }
    }

    private func retry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.connection == nil else { return }
            self.connect()
        }
    }

    func ask() { connection?.send(["op": "ask"]) }

    func get(_ section: String, _ key: String) -> Any? { (state[section] as? [String: Any])?[key] }
    func special(_ key: String) -> Any? { state[key] }

    func set(_ section: String, _ key: String, _ value: Any) {
        var s = state[section] as? [String: Any] ?? [:]; s[key] = value; state[section] = s   // shown at once; TurnOver confirms
        send([section: [key: value]])
    }
    func setSpecial(_ key: String, _ value: Any) { state[key] = value; send([key: value]) }

    private func send(_ patch: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: patch), let s = String(data: data, encoding: .utf8) else { return }
        connection?.send(["op": "patch", "json": s])
    }

    // Bindings onto the settings.
    func bool(_ section: String, _ key: String) -> Binding<Bool> {
        Binding(get: { self.get(section, key) as? Bool ?? false }, set: { self.set(section, key, $0) })
    }
    func string(_ section: String, _ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { self.get(section, key) as? String ?? fallback }, set: { self.set(section, key, $0) })
    }
    func int(_ section: String, _ key: String) -> Binding<Int> {
        Binding(get: { (self.get(section, key) as? NSNumber)?.intValue ?? 0 }, set: { self.set(section, key, $0) })
    }
    /// A 0–1 value shown as 0–100 (rate, pitch).
    func percent(_ section: String, _ key: String) -> Binding<Double> {
        Binding(get: { ((self.get(section, key) as? NSNumber)?.doubleValue ?? 0.5) * 100 }, set: { self.set(section, key, ($0 / 100 * 100).rounded() / 100) })
    }
    func number(_ section: String, _ key: String) -> Binding<Double> {
        Binding(get: { (self.get(section, key) as? NSNumber)?.doubleValue ?? 0 }, set: { self.set(section, key, Int($0.rounded())) })
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case speech = "Speech", braille = "Braille", keyboard = "Keyboard", documents = "Documents", webPages = "Web pages", sounds = "Sounds", general = "Starting", experimental = "Experimental"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $model.pane) { s in Text(s.rawValue).tag(s) }
                .navigationSplitViewColumnWidth(170)
                .accessibilityLabel("Settings sections")
        } detail: {
            if !model.connected {
                Text("Waiting for TurnOver. Start it with Command Control Period.").padding()
            } else {
                switch model.pane ?? .speech {
                case .speech: SpeechView()
                case .braille: BrailleView()
                case .keyboard: KeyboardView()
                case .documents: DocumentsView()
                case .webPages: WebPagesView()
                case .sounds: SoundsView()
                case .general: GeneralView()
                case .experimental: ExperimentalView()
                }
            }
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}

struct SpeechView: View {
    @EnvironmentObject var model: Model
    private let voices = AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    private let natural = ["af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river",
                           "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
                           "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis"]
    private var rotorChosen: [String] { (model.state["speech"] as? [String: Any])?["rotorVoices"] as? [String] ?? [] }
    /// The voices of the Mac's own languages (and English), as the rotor offers them.
    private var rotorCandidates: [AVSpeechSynthesisVoice] {
        let wanted = Set(Locale.preferredLanguages.map { String($0.prefix(2)) } + ["en"])
        return AVSpeechSynthesisVoice.speechVoices().filter { wanted.contains(String($0.language.prefix(2))) }
            .sorted { $0.name == $1.name ? $0.language < $1.language : $0.name < $1.name }
    }
    private func naturalName(_ v: String) -> String { "\(v.dropFirst(3).capitalized), \(v.hasPrefix("b") ? "British" : "American")" }
    var body: some View {
        Form {
            Picker("Voice", selection: model.string("speech", "voice", "")) {
                ForEach(voices, id: \.identifier) { v in
                    Text("\(v.name), \(Locale.current.localizedString(forIdentifier: v.language) ?? v.language)\(v.quality == .premium ? ", premium" : v.quality == .enhanced ? ", enhanced" : "")").tag(v.identifier)
                }
            }
            Slider(value: model.percent("speech", "rate"), in: 10...100, step: 5) { Text("Rate") }
                .accessibilityValue("\(Int(model.percent("speech", "rate").wrappedValue)) percent")
            Slider(value: model.percent("speech", "pitch"), in: 0...100, step: 5) { Text("Pitch") }
                .accessibilityValue("\(Int(model.percent("speech", "pitch").wrappedValue)) percent")
            Slider(value: model.number("speech", "volume"), in: 10...200, step: 10) { Text("Volume") }
                .accessibilityValue("\(Int(model.number("speech", "volume").wrappedValue)) percent")
            Picker("Punctuation", selection: model.int("speech", "symbolLevel")) {
                Text("None").tag(0); Text("Some").tag(1); Text("Most").tag(2); Text("All").tag(3)
            }
            Toggle("Switch language when text says it is in another", isOn: model.bool("speech", "autoLanguageSwitching"))
            // The speech rotor's own short list (18 Oct 2026): none ticked, every voice.
            Section("Voices in the rotor") {
                Text(rotorChosen.isEmpty ? "Every voice: tick the ones you want VO-Command-Shift to step through." : "\(rotorChosen.count) chosen for VO-Command-Shift.").font(.caption)
                ForEach(rotorCandidates, id: \.identifier) { v in
                    Toggle("\(v.name), \(Locale.current.localizedString(forIdentifier: v.language) ?? v.language)", isOn: Binding(
                        get: { rotorChosen.contains(v.identifier) },
                        set: { on in
                            var list = rotorChosen.filter { $0 != v.identifier }
                            if on { list.append(v.identifier) }
                            model.set("speech", "rotorVoices", list)
                        }))
                }
            }
            if model.special("_kokoroAvailable") as? Bool == true {
                Section("Say all") {
                    Picker("Say all voice", selection: Binding(
                        get: { (model.special("_kokoroMode") as? String) == "off" ? "same" : (model.special("_kokoroVoice") as? String ?? "bf_emma") },
                        set: { v in if v == "same" { model.setSpecial("_kokoroMode", "off") } else { model.setSpecial("_kokoroVoice", v); model.setSpecial("_kokoroMode", "reading") } })) {
                        Text("Same as speech").tag("same")
                        ForEach(natural, id: \.self) { Text("\(naturalName($0)), natural").tag($0) }
                    }
                    Slider(value: Binding(get: { model.special("_kokoroSpeed") as? Double ?? 1.1 }, set: { model.setSpecial("_kokoroSpeed", ($0 * 10).rounded() / 10) }), in: 0.6...2.0, step: 0.1) { Text("Natural voice speed") }
                    Text("Say all reads ahead in the natural voice; moving around and typing stay in your speech voice.").font(.caption)
                }
            }
        }.formStyle(.grouped).navigationTitle("Speech")
    }
}

/// NVDA's braille settings, as TurnOver has them (the TurnOver menu's Braille has the same).
struct BrailleView: View {
    @EnvironmentObject var model: Model
    private var tables: [[String]] { model.special("_brailleTables") as? [[String]] ?? [] }
    private func shapes(_ title: String, _ key: String, _ fallback: String) -> some View {
        Picker(title, selection: model.string("braille", key, fallback)) {
            Text("Dots 7 and 8").tag("78"); Text("Dot 8").tag("8"); Text("All dots").tag("all")
        }
    }
    var body: some View {
        Form {
            Section("Text") {
                Picker("Braille table", selection: model.string("braille", "table", "")) {
                    Text("The system's for my language").tag("")
                    ForEach(tables.filter { $0.count == 2 }, id: \.[0]) { t in Text(t[1]).tag(t[0]) }
                }
                Toggle("Show the word at the cursor uncontracted", isOn: model.bool("braille", "expandAtCursor"))
                Toggle("Keep words whole", isOn: model.bool("braille", "wordWrap"))
                Toggle("Read by paragraph", isOn: model.bool("braille", "readByParagraph"))
            }
            Section("Following") {
                Picker("Braille follows", selection: model.string("braille", "tether", "auto")) {
                    Text("Automatically").tag("auto"); Text("The focus").tag("focus"); Text("The review cursor").tag("review")
                }
                Picker("Braille mode", selection: model.string("braille", "mode", "followCursors")) {
                    Text("Follow the cursors").tag("followCursors"); Text("Show what is spoken").tag("speechOutput")
                }
                Picker("Focus context", selection: model.string("braille", "focusContext", "changes")) {
                    Text("Fill the display when the context changes").tag("changes"); Text("Only when panning back").tag("scroll"); Text("Always fill the display").tag("always")
                }
                Picker("Panning moves the cursor", selection: model.string("braille", "panMovesCaret", "line")) {
                    Text("Line by line").tag("line"); Text("To the text shown").tag("window"); Text("Off").tag("off")
                }
                Toggle("Stop speech while panning", isOn: model.bool("braille", "interruptSpeechWhileScrolling"))
                Toggle("Speak the character when routing", isOn: model.bool("braille", "speakCharacterOnRouting"))
            }
            Section("Cursor") {
                Toggle("Show the cursor", isOn: model.bool("braille", "showCursor"))
                Toggle("Blink", isOn: model.bool("braille", "blinkCursor"))
                Stepper("Blink rate: \(model.number("braille", "blinkRateMs").wrappedValue, specifier: "%.0f") milliseconds",
                        value: model.number("braille", "blinkRateMs"), in: 200...2000, step: 100)
                shapes("Cursor shape", "cursorShape", "78")
                shapes("Review cursor shape", "cursorShapeReview", "8")
                Toggle("Selection with dots 7 and 8", isOn: model.bool("braille", "showSelection"))
            }
            Section("Messages") {
                Picker("Messages on the display", selection: model.string("braille", "showMessages", "timeout")) {
                    Text("For a time").tag("timeout"); Text("Until a key is pressed").tag("indefinitely"); Text("Off").tag("off")
                }
                Stepper("Message time: \(model.number("braille", "messageSeconds").wrappedValue, specifier: "%.0f") seconds",
                        value: model.number("braille", "messageSeconds"), in: 1...30, step: 1)
            }
            Section("Braille keyboard") {
                Picker("Typing", selection: model.bool("braille", "contractedInput")) {
                    Text("Contracted, a word at a time").tag(true); Text("Uncontracted, letter by letter").tag(false)
                }
                Picker("Speak braille typing", selection: model.string("braille", "inputEcho", "words")) {
                    Text("Words").tag("words"); Text("Characters").tag("characters"); Text("Characters and words").tag("both"); Text("Off").tag("off")
                }
            }
            Section("Displays") {
                Toggle("Look for a display paired over Bluetooth", isOn: model.bool("braille", "bluetooth"))
            }
        }.formStyle(.grouped).navigationTitle("Braille")
    }
}

struct KeyboardView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Picker("Keyboard style", selection: model.string("general", "keyboardStyle", "mac")) {
                Text("VoiceOver keys").tag("mac"); Text("NVDA keys").tag("windows"); Text("JAWS keys").tag("jaws")
            }
            Picker("TurnOver key", selection: model.string("general", "bosunKey", "both")) {
                Text("Caps Lock or Control Option").tag("both"); Text("Caps Lock").tag("caps"); Text("Control Option").tag("controlOption")
            }
            Picker("Speak typed characters", selection: model.int("keyboard", "speakTypedCharacters")) {
                Text("Off").tag(0); Text("In edit fields").tag(1); Text("Always").tag(2)
            }
            Picker("Speak typed words", selection: model.int("keyboard", "speakTypedWords")) {
                Text("Off").tag(0); Text("In edit fields").tag(1); Text("Always").tag(2)
            }
            Toggle("Speak command keys", isOn: model.bool("keyboard", "speakCommandKeys"))
        }.formStyle(.grouped).navigationTitle("Keyboard")
    }
}

struct DocumentsView: View {
    @EnvironmentObject var model: Model
    private let kinds: [(String, String)] = [("headings", "Headings"), ("links", "Links"), ("lists", "Lists"), ("tables", "Tables"),
                                              ("landmarks", "Landmarks"), ("graphics", "Graphics"), ("blockQuotes", "Block quotes"), ("spellingErrors", "Spelling errors")]
    var body: some View {
        Form {
            ForEach(kinds, id: \.0) { k in
                Picker(k.1, selection: model.string("documentFormatting", k.0, "speech")) {
                    Text("Said").tag("speech"); Text("A sound").tag("tone"); Text("Nothing").tag("off")
                }
            }
            Toggle("Say heading levels", isOn: model.bool("documentFormatting", "reportHeadingLevel"))
            Toggle("Say table headers", isOn: model.bool("documentFormatting", "tableHeaders"))
            Toggle("Say table cell positions", isOn: model.bool("documentFormatting", "tableCellCoordinates"))
            Toggle("Say bold, italic and underline", isOn: model.bool("documentFormatting", "reportFontAttributes"))
        }.formStyle(.grouped).navigationTitle("Documents")
    }
}

struct WebPagesView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Toggle("Type into a field as soon as it has the focus", isOn: model.bool("virtualBuffers", "autoFocusMode"))
            Toggle("Read a page through as it opens", isOn: model.bool("virtualBuffers", "autoSayAllOnPageLoad"))
            Toggle("Single-letter keys wrap at the end of the page", isOn: model.bool("virtualBuffers", "wrapQuickNav"))
            Toggle("Keep the page's own lines", isOn: model.bool("virtualBuffers", "screenLayout"))
        }.formStyle(.grouped).navigationTitle("Web pages")
    }
}

struct SoundsView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Picker("Sounds", selection: model.string("general", "sounds", "turnover")) {
                Text("VoiceOver's").tag("voiceover"); Text("TurnOver's").tag("turnover")
            }
            Toggle("Sounds as I move and press", isOn: model.bool("general", "navigationSounds"))
            Toggle("Read notifications from other apps", isOn: model.bool("presentation", "reportNotifications"))
            Toggle("Read changes on screen as they happen", isOn: model.bool("presentation", "reportDynamicContentChanges"))
        }.formStyle(.grouped).navigationTitle("Sounds")
    }
}

struct GeneralView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Toggle("Open TurnOver at login", isOn: model.bool("general", "openAtLogin"))
            Toggle("Show TurnOver in the menu bar", isOn: model.bool("general", "showInMenuBar"))
        }.formStyle(.grouped).navigationTitle("Starting")
    }
}

struct ExperimentalView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Form {
            Section {
                Toggle("CoExist", isOn: Binding(get: { model.special("_coexist") as? Bool ?? false }, set: { model.setSpecial("_coexist", $0) }))
                Text("CoExist keeps VoiceOver running alongside TurnOver: TurnOver reads the apps on its list, and VoiceOver, kept quiet there, reads every other app straight away. Changing it restarts TurnOver; turning it on, VoiceOver Utility opens and closes by itself once.").font(.caption)
            } header: { Text("Newer features, still settling") }
        }.formStyle(.grouped).navigationTitle("Experimental")
    }
}

@main
struct TurnOverSettingsApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup("TurnOver Settings") { ContentView().environmentObject(model) }
            .windowResizability(.contentSize)
    }
}
