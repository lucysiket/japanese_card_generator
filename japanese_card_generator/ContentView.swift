//
//  ContentView.swift
//  Japanese Card Generator
//

import SwiftUI
import UIKit
import SQLite3
internal import Combine
import PhotosUI

private enum PinkTheme {
    static let background = Color(red: 0.96, green: 0.82, blue: 0.90)
    static let row = Color(red: 1.0, green: 0.94, blue: 0.97)
    static let accent = Color(red: 0.77, green: 0.34, blue: 0.55)
    static let text = Color(red: 0.36, green: 0.20, blue: 0.29)
}

private extension View {
    func pinkFormStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(PinkTheme.background)
            .tint(PinkTheme.accent)
            .foregroundStyle(PinkTheme.text)
    }

    func pinkRowStyle() -> some View {
        listRowBackground(PinkTheme.row)
    }

    func whiteInputRowStyle() -> some View {
        listRowBackground(Color.white)
    }
}

struct Flashcard {
    var expression = ""
    var reading = ""
    var meaning = ""
    var category = ""
    var exampleJapanese = ""
    var exampleEnglish = ""
    var notes = ""
    var themes: Set<String> = []
    var noteImageData: Data? = nil

    var isReadyForAnki: Bool {
        !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct JMdictLookup {
    var id: Int64
    var expression: String
    var reading: String
    var meaning: String
    var partOfSpeech: String
    var tags: String
    var category: String
    var themes: Set<String>
    var exampleJapanese: String
    var exampleEnglish: String
}

struct JMdictService {
    enum JMdictError: LocalizedError {
        case missingDictionary
        case openFailed
        case queryFailed

        var errorDescription: String? {
            switch self {
            case .missingDictionary:
                return "The offline dictionary database could not be found in the app bundle."
            case .openFailed:
                return "The offline dictionary database could not be opened."
            case .queryFailed:
                return "The offline dictionary lookup failed."
            }
        }
    }

    func lookups(_ expression: String) async throws -> [JMdictLookup] {
        let cleanExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanExpression.isEmpty else { return [] }

        return try await Task.detached(priority: .userInitiated) {
            try lookupsInDatabase(cleanExpression)
        }.value
    }

    nonisolated private func lookupsInDatabase(_ key: String) throws -> [JMdictLookup] {
        guard let url = Bundle.main.url(forResource: "JapaneseDictionary", withExtension: "sqlite") else {
            throw JMdictError.missingDictionary
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw JMdictError.openFailed
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT entries.id, expression, reading, meaning, part_of_speech, tags, category, themes, example_japanese, example_english
        FROM entries
        JOIN search_keys ON entries.id = search_keys.entry_id
        WHERE search_keys.key = ?
        GROUP BY entries.id
        ORDER BY
            CASE entries.source WHEN 'jmdict' THEN 0 ELSE 1 END,
            entries.priority DESC,
            entries.id ASC
        LIMIT 8
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw JMdictError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var lookups: [JMdictLookup] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            lookups.append(JMdictLookup(
                id: sqlite3_column_int64(statement, 0),
                expression: Self.text(statement, 1),
                reading: key.containsKanji ? Self.text(statement, 2).katakanaConvertedToHiragana() : key,
                meaning: Self.text(statement, 3),
                partOfSpeech: Self.text(statement, 4),
                tags: Self.text(statement, 5),
                category: Self.text(statement, 6),
                themes: Set(Self.text(statement, 7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
                exampleJapanese: Self.text(statement, 8),
                exampleEnglish: Self.text(statement, 9)
            ))
        }

        return lookups
    }

    nonisolated private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: cString)
    }
}

private extension String {
    nonisolated var containsKanji: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    nonisolated func katakanaConvertedToHiragana() -> String {
        String(unicodeScalars.map { scalar in
            let value = scalar.value

            if (0x30A1...0x30F6).contains(value),
               let hiraganaScalar = UnicodeScalar(value - 0x60) {
                return Character(hiraganaScalar)
            }

            return Character(scalar)
        })
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let defaultCategories = [
        "Time-Numbers",
        "Nouns",
        "Names",
        "Verbs",
        "Adjectives",
        "Phrases",
        "Grammar"
    ]

    static let defaultThemes = [
        "Nature",
        "Time",
        "Counters",
        "People",
        "Names",
        "Places",
        "Japan",
        "Buildings/Facilities",
        "Transport",
        "Food/Drink",
        "Body/Health",
        "Animals",
        "Objects",
        "Study/Language",
        "Work/Society",
        "Weather",
        "Feelings",
        "Position/Direction",
        "Quantity/Degree",
        "Activities/Leisure",
        "Days_of_the_week",
        "Days_of_the_month",
        "Emergency/Disaster"
    ]

    @Published var deckName: String {
        didSet { UserDefaults.standard.set(deckName, forKey: "deckName") }
    }

    @Published var noteTypeName: String {
        didSet { UserDefaults.standard.set(noteTypeName, forKey: "noteTypeName") }
    }

    @Published var deckNames: [String] {
        didSet { UserDefaults.standard.set(deckNames, forKey: "deckNames") }
    }

    @Published var noteTypeNames: [String] {
        didSet { UserDefaults.standard.set(noteTypeNames, forKey: "noteTypeNames") }
    }

    @Published var customCategories: [String] {
        didSet { UserDefaults.standard.set(customCategories, forKey: "customCategories") }
    }

    @Published var customThemes: [String] {
        didSet { UserDefaults.standard.set(customThemes, forKey: "customThemes") }
    }

    @Published var appNote: String {
        didSet { UserDefaults.standard.set(appNote, forKey: "appNote") }
    }

    var categories: [String] {
        Self.defaultCategories + customCategories
    }

    var themes: [String] {
        Self.defaultThemes + customThemes
    }

    var availableDeckNames: [String] {
        deckNames
    }

    init() {
        deckName = UserDefaults.standard.string(forKey: "deckName") ?? ""
        noteTypeName = UserDefaults.standard.string(forKey: "noteTypeName") ?? ""
        deckNames = UserDefaults.standard.stringArray(forKey: "deckNames") ?? []
        noteTypeNames = UserDefaults.standard.stringArray(forKey: "noteTypeNames") ?? []
        customCategories = UserDefaults.standard.stringArray(forKey: "customCategories") ?? []
        customThemes = UserDefaults.standard.stringArray(forKey: "customThemes") ?? []
        appNote = UserDefaults.standard.string(forKey: "appNote") ?? ""

        if !availableDeckNames.isEmpty, !availableDeckNames.contains(deckName) {
            deckName = availableDeckNames[0]
        }

        if !noteTypeNames.isEmpty, !noteTypeNames.contains(noteTypeName) {
            noteTypeName = noteTypeNames[0]
        }
    }

    func updateAnkiInfo(_ info: AnkiAddingInfo) {
        deckNames = info.decks
        noteTypeNames = info.noteTypes

        if !availableDeckNames.isEmpty, !availableDeckNames.contains(deckName) {
            deckName = availableDeckNames[0]
        }

        if !noteTypeNames.isEmpty, !noteTypeNames.contains(noteTypeName) {
            noteTypeName = noteTypeNames[0]
        }
    }

    func selectDeck(_ deckName: String) {
        self.deckName = deckName
    }

    func addCategory(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !categories.contains(clean) else { return }
        customCategories.append(clean)
    }

    func addTheme(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !themes.contains(clean) else { return }
        customThemes.append(clean)
    }

    func clearAllData() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "deckName")
        defaults.removeObject(forKey: "noteTypeName")
        defaults.removeObject(forKey: "deckNames")
        defaults.removeObject(forKey: "noteTypeNames")
        defaults.removeObject(forKey: "customCategories")
        defaults.removeObject(forKey: "customThemes")
        defaults.removeObject(forKey: "appNote")

        // Reset in-memory state
        deckName = ""
        noteTypeName = ""
        deckNames = []
        noteTypeNames = []
        customCategories = []
        customThemes = []
        appNote = ""
    }
}

struct AnkiAddingInfo {
    var decks: [String]
    var noteTypes: [String]
}

struct AnkiService {
    private static let pasteboardType = "net.ankimobile.json"

    enum AnkiError: LocalizedError {
        case missingSettings
        case invalidURL
        case cannotOpenAnki
        case noAddingInfo
        case invalidAddingInfo

        var errorDescription: String? {
            switch self {
            case .missingSettings:
                return "Set your Anki deck and note type in Settings first."
            case .invalidURL:
                return "The Anki note URL could not be created."
            case .cannotOpenAnki:
                return "AnkiMobile could not be opened. Make sure it is installed on this iPhone."
            case .noAddingInfo:
                return "No Anki deck or note type data was found. Approve the request in AnkiMobile, then return to this app."
            case .invalidAddingInfo:
                return "Anki returned data, but it could not be read."
            }
        }
    }

    func requestInfoForAdding() async throws {
        var components = URLComponents()
        components.scheme = "anki"
        components.host = "x-callback-url"
        components.path = "/infoForAdding"
        components.queryItems = [
            URLQueryItem(name: "x-success", value: "japanese-card-generator://anki-info")
        ]

        guard let url = components.url else {
            throw AnkiError.invalidURL
        }

        let opened = await UIApplication.shared.open(url)
        if !opened {
            throw AnkiError.cannotOpenAnki
        }
    }

    func addingInfoFromPasteboard() throws -> AnkiAddingInfo? {
        guard let data = UIPasteboard.general.data(forPasteboardType: Self.pasteboardType) else {
            return nil
        }

        UIPasteboard.general.setData(Data(), forPasteboardType: Self.pasteboardType)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnkiError.invalidAddingInfo
        }

        let decks = Self.extractStrings(from: object, matching: { key in
            key.contains("deck")
        })
        let noteTypes = Self.extractStrings(from: object, matching: { key in
            key.contains("notetype") || key.contains("note_type") || key.contains("note type") || key.contains("model")
        })

        guard !decks.isEmpty || !noteTypes.isEmpty else {
            throw AnkiError.noAddingInfo
        }

        return AnkiAddingInfo(decks: decks, noteTypes: noteTypes)
    }

    func add(card: Flashcard, deck: String, noteType: String) async throws {
        let cleanDeck = deck.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanType = noteType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDeck.isEmpty, !cleanType.isEmpty else {
            throw AnkiError.missingSettings
        }

        var components = URLComponents()
        components.scheme = "anki"
        components.host = "x-callback-url"
        components.path = "/addnote"

        let notesWithImage: String
        if let data = card.noteImageData {
            let base64 = data.base64EncodedString()
            notesWithImage = card.notes + "<br><img src=\"data:image/jpeg;base64,\(base64)\" alt=\"note image\" />"
        } else {
            notesWithImage = card.notes
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: cleanType),
            URLQueryItem(name: "deck", value: cleanDeck),
            URLQueryItem(name: "fldExpression", value: card.expression),
            URLQueryItem(name: "fldReading", value: card.reading),
            URLQueryItem(name: "fldMeaning", value: card.meaning),
            URLQueryItem(name: "fldCategory", value: card.category),
            URLQueryItem(name: "fldExample Japanese", value: card.exampleJapanese),
            URLQueryItem(name: "fldExample English", value: card.exampleEnglish),
            URLQueryItem(name: "fldNotes", value: notesWithImage),
            URLQueryItem(name: "tags", value: card.themes.sorted().joined(separator: " "))
        ]

        guard let url = components.url else {
            throw AnkiError.invalidURL
        }

        let opened = await UIApplication.shared.open(url)
        if !opened {
            throw AnkiError.cannotOpenAnki
        }
    }

    nonisolated private static func extractStrings(
        from value: Any,
        matching matchesKey: (String) -> Bool,
        parentKey: String = ""
    ) -> [String] {
        var results: [String] = []

        if let dictionary = value as? [String: Any] {
            for (key, nestedValue) in dictionary {
                let normalizedKey = key.lowercased()

                if matchesKey(normalizedKey) {
                    results.append(contentsOf: strings(in: nestedValue))
                } else {
                    results.append(contentsOf: extractStrings(
                        from: nestedValue,
                        matching: matchesKey,
                        parentKey: normalizedKey
                    ))
                }
            }
        } else if matchesKey(parentKey) {
            results.append(contentsOf: strings(in: value))
        }

        return Array(NSOrderedSet(array: results)) as? [String] ?? results
    }

    nonisolated private static func strings(in value: Any) -> [String] {
        if let string = value as? String {
            let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? [] : [clean]
        }

        if let strings = value as? [String] {
            return strings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        if let array = value as? [Any] {
            return array.flatMap(strings)
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap(strings)
        }

        return []
    }
}

struct ContentView: View {
    @StateObject private var settings = AppSettings()

    @State private var card = Flashcard()
    @State private var sourceExpression = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var dictionaryMessage: String?
    @State private var dictionaryOptions: [JMdictLookup] = []
    @State private var selectedDictionaryOptionID: Int64?
    @State private var showNotes = false
    @State private var showSettings = false
    @State private var showAddCategory = false
    @State private var showAddTheme = false
    @State private var newCategoryName = ""
    @State private var newThemeName = ""
    @State private var isAddingToAnki = false
    @State private var selectedNotesPhotoItem: PhotosPickerItem? = nil
    @State private var showCameraPicker = false

    private let dictionary = JMdictService()
    private let anki = AnkiService()

    private var cleanSourceExpression: String {
        sourceExpression.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cardForAnki: Flashcard {
        var ankiCard = card
        ankiCard.expression = cleanSourceExpression
        return ankiCard
    }

    var body: some View {
        NavigationStack {
            Form {
                expressionGenerationSection
                cardCreationSection

                ankiSection
            }
            .pinkFormStyle()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showNotes = true
                    } label: {
                        Image(systemName: "note.text")
                            .foregroundStyle(PinkTheme.accent)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(PinkTheme.accent)
                    }
                }
            }
            .sheet(isPresented: $showNotes) {
                SimpleNotesView(note: $settings.appNote)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings)
            }
            .sheet(isPresented: $showCameraPicker) {
                CameraPicker { image in
                    if let data = image.jpegData(compressionQuality: 0.9) {
                        card.noteImageData = data
                    }
                }
            }
            .alert("New Category", isPresented: $showAddCategory) {
                TextField("Category", text: $newCategoryName)
                    .textInputAutocapitalization(.words)
                Button("Add") { addCategoryFromSelectionMenu() }
                Button("Cancel", role: .cancel) { newCategoryName = "" }
            }
            .alert("New Theme", isPresented: $showAddTheme) {
                TextField("Theme", text: $newThemeName)
                    .textInputAutocapitalization(.words)
                Button("Add") { addThemeFromSelectionMenu() }
                Button("Cancel", role: .cancel) { newThemeName = "" }
            }
            .alert("Japanese Cards", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var expressionGenerationSection: some View {
        Section {
            TextField("Expression", text: $sourceExpression)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(false)
                .keyboardType(.default)
                .whiteInputRowStyle()

            Button {
                Task { await generateCard() }
            } label: {
                HStack {
                    if isGenerating {
                        ProgressView()
                    }
                    Text(isGenerating ? "Generating..." : "Generate")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(cleanSourceExpression.isEmpty || isGenerating)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

            if let dictionaryMessage {
                Label(dictionaryMessage, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(PinkTheme.accent)
                    .pinkRowStyle()
            }

            if dictionaryOptions.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(dictionaryOptions.enumerated()), id: \.element.id) { index, lookup in
                            Button {
                                applyLookup(lookup)
                            } label: {
                                Text(dictionaryOptionTitle(for: lookup, number: index + 1))
                                    .font(.footnote)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedDictionaryOptionID == lookup.id ? .accentColor : .secondary)
                        }
                    }
                }
                .pinkRowStyle()
            }
        }
    }

    private var cardCreationSection: some View {
        Section {
            TextField("Reading", text: $card.reading)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(false)
                .keyboardType(.default)
                .whiteInputRowStyle()

            TextField("Meaning", text: $card.meaning)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .keyboardType(.asciiCapable)
                .whiteInputRowStyle()

            TextField("Japanese", text: $card.exampleJapanese)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(false)
                .keyboardType(.default)
                .whiteInputRowStyle()

            TextField("English", text: $card.exampleEnglish)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(false)
                .keyboardType(.asciiCapable)
                .whiteInputRowStyle()

            TextField("Notes", text: $card.notes)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .keyboardType(.asciiCapable)
                .whiteInputRowStyle()

            HStack {
                PhotosPicker(selection: $selectedNotesPhotoItem, matching: .images, photoLibrary: .shared()) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                }
                Button {
                    showCameraPicker = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            .buttonStyle(.bordered)
            .tint(PinkTheme.accent)
            .onChange(of: selectedNotesPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        card.noteImageData = data
                    }
                }
            }
            .pinkRowStyle()

            if let data = card.noteImageData, let image = UIImage(data: data) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button {
                        card.noteImageData = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                            .padding(6)
                    }
                    .background(Color.black.opacity(0.4))
                    .clipShape(Circle())
                    .padding(8)
                    .accessibilityLabel("Remove image")
                }
                .padding(.vertical, 8)
                .pinkRowStyle()
            }

            categorySelectionRow

            LabeledContent("Selected") {
                Text(selectedThemesText)
                    .foregroundStyle(card.themes.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
            }
            .pinkRowStyle()

            Menu {
                ForEach(settings.themes, id: \.self) { theme in
                    Button {
                        toggleTheme(theme)
                    } label: {
                        if card.themes.contains(theme) {
                            Label(theme, systemImage: "checkmark")
                        } else {
                            Text(theme)
                        }
                    }
                }

                if !card.themes.isEmpty {
                    Divider()

                    Button("Clear selected", role: .destructive) {
                        card.themes.removeAll()
                    }
                }

                Divider()

                Button {
                    newThemeName = ""
                    showAddTheme = true
                } label: {
                    Label("Add new", systemImage: "plus")
                }
            } label: {
                Label("Choose themes", systemImage: "tag")
            }
            .pinkRowStyle()
        }
    }

    private var categorySelectionRow: some View {
        LabeledContent("Category") {
            Menu {
                Button {
                    card.category = ""
                } label: {
                    if card.category.isEmpty {
                        Label("Select", systemImage: "checkmark")
                    } else {
                        Text("Select")
                    }
                }

                ForEach(settings.categories, id: \.self) { category in
                    Button {
                        card.category = category
                    } label: {
                        if card.category == category {
                            Label(category, systemImage: "checkmark")
                        } else {
                            Text(category)
                        }
                    }
                }

                Divider()

                Button {
                    newCategoryName = ""
                    showAddCategory = true
                } label: {
                    Label("Add new", systemImage: "plus")
                }
            } label: {
                Text(card.category.isEmpty ? "Select" : card.category)
            }
        }
        .pinkRowStyle()
    }

    private var selectedThemesText: String {
        if card.themes.isEmpty {
            return "None"
        }

        return card.themes.sorted().joined(separator: ", ")
    }

    private func toggleTheme(_ theme: String) {
        if card.themes.contains(theme) {
            card.themes.remove(theme)
        } else {
            card.themes.insert(theme)
        }
    }

    private func addCategoryFromSelectionMenu() {
        let cleanName = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        settings.addCategory(cleanName)
        card.category = cleanName
        newCategoryName = ""
    }

    private func addThemeFromSelectionMenu() {
        let cleanName = newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        settings.addTheme(cleanName)
        card.themes.insert(cleanName)
        newThemeName = ""
    }

    private func lookupCategory(_ lookup: JMdictLookup) -> String {
        settings.categories.contains(lookup.category) ? lookup.category : ""
    }

    @MainActor
    private func applyLookup(_ lookup: JMdictLookup) {
        selectedDictionaryOptionID = lookup.id
        card = Flashcard(
            expression: lookup.expression,
            reading: lookup.reading,
            meaning: lookup.meaning,
            category: lookupCategory(lookup),
            exampleJapanese: lookup.exampleJapanese,
            exampleEnglish: lookup.exampleEnglish,
            notes: "",
            themes: Set(lookup.themes.filter(settings.themes.contains)),
            noteImageData: nil
        )
    }

    private func dictionaryOptionTitle(for lookup: JMdictLookup, number: Int) -> String {
        let cleanMeaning = lookup.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanMeaning.isEmpty {
            return "Option \(number)"
        }

        return "\(number). \(cleanMeaning)"
    }

    private var ankiSection: some View {
        Section {
            Button {
                Task { await addToAnki() }
            } label: {
                HStack {
                    if isAddingToAnki {
                        ProgressView()
                    }
                    Label("Add to Anki", systemImage: "rectangle.stack.badge.plus")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isAddingToAnki ||
                !cardForAnki.isReadyForAnki ||
                settings.deckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .pinkRowStyle()
    }

    @MainActor
    private func generateCard() async {
        isGenerating = true
        dictionaryMessage = nil
        defer { isGenerating = false }

        do {
            let lookups = try await dictionary.lookups(cleanSourceExpression)
            dictionaryOptions = lookups
            selectedDictionaryOptionID = nil

            if let firstLookup = lookups.first {
                applyLookup(firstLookup)
                if lookups.count > 1 {
                    dictionaryMessage = "\(lookups.count) definitions found. Choose one below."
                }
            } else {
                dictionaryOptions = []
                dictionaryMessage = "Not available in the dictionary."
            }
        } catch {
            dictionaryOptions = []
            selectedDictionaryOptionID = nil
            dictionaryMessage = error.localizedDescription
        }
    }

    @MainActor
    private func addToAnki() async {
        isAddingToAnki = true
        errorMessage = nil
        defer { isAddingToAnki = false }

        do {
            try await anki.add(
                card: cardForAnki,
                deck: settings.deckName,
                noteType: settings.noteTypeName
            )
            clearCard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func clearCard() {
        sourceExpression = ""
        card = Flashcard()
        dictionaryMessage = nil
        dictionaryOptions = []
        selectedDictionaryOptionID = nil
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var isRequestingAnkiInfo = false
    @State private var statusMessage: String?

    private let anki = AnkiService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Anki") {
                    if settings.availableDeckNames.isEmpty {
                        LabeledContent("Deck") {
                            Text("No deck yet")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Deck", selection: $settings.deckName) {
                            ForEach(settings.availableDeckNames, id: \.self) { deckName in
                                Text(deckName).tag(deckName)
                            }
                        }
                    }

                    if settings.noteTypeNames.isEmpty {
                        LabeledContent("Note type") {
                            Text("No note type yet")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Note type", selection: $settings.noteTypeName) {
                            ForEach(settings.noteTypeNames, id: \.self) { noteTypeName in
                                Text(noteTypeName).tag(noteTypeName)
                            }
                        }
                    }

                    Button {
                        Task { await requestAnkiInfo() }
                    } label: {
                        HStack {
                            if isRequestingAnkiInfo {
                                ProgressView()
                            }
                            Text(settings.deckNames.isEmpty && settings.noteTypeNames.isEmpty ? "Open Anki" : "Refresh from Anki")
                        }
                    }
                    .disabled(isRequestingAnkiInfo)
                }
                .pinkRowStyle()
            }
            .pinkFormStyle()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadAnkiInfoFromPasteboard()
            }
            .onOpenURL { _ in
                loadAnkiInfoFromPasteboard()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    loadAnkiInfoFromPasteboard()
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(.headline)
                        .foregroundStyle(PinkTheme.text)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func requestAnkiInfo() async {
        isRequestingAnkiInfo = true
        statusMessage = "Approve the request in AnkiMobile, then return here."
        defer { isRequestingAnkiInfo = false }

        do {
            try await anki.requestInfoForAdding()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadAnkiInfoFromPasteboard() {
        do {
            guard let info = try anki.addingInfoFromPasteboard() else {
                return
            }

            settings.updateAnkiInfo(info)
            let deckText = info.decks.count == 1 ? "1 deck" : "\(info.decks.count) decks"
            let noteTypeText = info.noteTypes.count == 1 ? "1 note type" : "\(info.noteTypes.count) note types"
            statusMessage = "Fetched \(deckText) and \(noteTypeText) from AnkiMobile."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

struct SimpleNotesView: View {
    @Binding var note: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                PinkTheme.background
                    .ignoresSafeArea()

                VStack {
                    TextEditor(text: $note)
                        .padding(12)
                        .scrollContentBackground(.hidden)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(PinkTheme.text)
                        .padding()
                }
            }
            .tint(PinkTheme.accent)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(PinkTheme.background, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Notes")
                        .font(.headline)
                        .foregroundStyle(PinkTheme.text)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIImagePickerController

    var onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void

        init(onImage: @escaping (UIImage) -> Void) {
            self.onImage = onImage
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

#Preview {
    ContentView()
}
