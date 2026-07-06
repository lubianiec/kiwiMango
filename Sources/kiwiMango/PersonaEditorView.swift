import SwiftUI

// MARK: - PersonaEditorView

/// Sheet: list of saved personas + add/edit/delete. Opened from the persona
/// picker in `ChatView`'s top bar.
struct PersonaEditorView: View {

    @Environment(ChatState.self) private var chatState
    @Environment(\.dismiss) private var dismiss

    @State private var editingPersona: Persona?
    @State private var showingForm = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            content
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(Color.kiwiMangoSurface)
        .sheet(isPresented: $showingForm) {
            PersonaFormView(persona: editingPersona)
        }
    }

    private var titleBar: some View {
        HStack {
            Text("PERSONY")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Spacer()
            Button {
                editingPersona = nil
                showingForm = true
            } label: {
                Text("+ NOWA")
                    .font(KiwiMangoFont.mono(10.5, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoAccentText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            Button("Zamknij") { dismiss() }
                .buttonStyle(.plain)
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.kiwiMangoChrome)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                Divider().overlay(Color.white.opacity(0.1))
                ForEach(chatState.personas) { persona in
                    personaRow(persona)
                    Divider().overlay(Color.white.opacity(0.1))
                }
            }
        }
    }

    private func personaRow(_ persona: Persona) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(persona.name)
                    .font(KiwiMangoFont.sans(13, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                Text(persona.systemPrompt.isEmpty ? "brak system promptu" : persona.systemPrompt)
                    .font(KiwiMangoFont.sans(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer()
            Text(String(format: "%.1f", persona.temperature))
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoAccent.opacity(0.8))
            Button {
                editingPersona = persona
                showingForm = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            Button {
                chatState.deletePersona(persona.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kiwiMangoDanger)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - PersonaFormView

private struct PersonaFormView: View {
    let persona: Persona?

    @Environment(ChatState.self) private var chatState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var systemPrompt: String
    @State private var useCustomModel: Bool
    @State private var model: String
    @State private var temperature: Double

    init(persona: Persona?) {
        self.persona = persona
        _name = State(initialValue: persona?.name ?? "")
        _systemPrompt = State(initialValue: persona?.systemPrompt ?? "")
        _useCustomModel = State(initialValue: persona?.model != nil)
        _model = State(initialValue: persona?.model ?? "")
        _temperature = State(initialValue: persona?.temperature ?? 0.8)
    }

    var body: some View {
        Form {
            Section("Nazwa") {
                TextField("np. KREATYWNY", text: $name)
            }
            Section("System prompt") {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 120)
                    .font(.system(size: 12, design: .monospaced))
            }
            Section("Model") {
                Toggle("Wymuś konkretny model", isOn: $useCustomModel)
                if useCustomModel {
                    Picker("Model", selection: $model) {
                        ForEach(chatState.availableModels, id: \.name) { info in
                            Text(info.isCloud ? "☁️ \(info.name)" : info.name).tag(info.name)
                        }
                    }
                }
            }
            Section("Temperatura: \(String(format: "%.2f", temperature))") {
                Slider(value: $temperature, in: 0...1.5, step: 0.05)
            }
        }
        .padding(20)
        .frame(width: 420, height: 420)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }
                Button("Zapisz") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
    }

    private func save() {
        let saved = Persona(
            id: persona?.id ?? 0,
            name: name.trimmingCharacters(in: .whitespaces),
            systemPrompt: systemPrompt,
            model: useCustomModel && !model.isEmpty ? model : nil,
            temperature: temperature,
            position: persona?.position ?? chatState.personas.count
        )
        chatState.savePersona(saved)
        dismiss()
    }
}
