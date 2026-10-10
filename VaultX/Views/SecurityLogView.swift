import SwiftUI

extension SecurityEvent.Kind {

    var title: String {

        switch self {
        case .vaultCreated: return "Vault creato"
        case .unlockSucceeded: return "Sblocco riuscito"
        case .unlockFailed: return "Tentativo di sblocco fallito"
        case .passwordChanged: return "Password cambiata"
        case .passwordReset: return "Password reimpostata (chiave di recupero)"
        case .recoveryKeyCreated: return "Chiave di recupero generata"
        case .recoveryKeyRemoved: return "Chiave di recupero rimossa"
        case .biometricEnabled: return "Sblocco biometrico attivato"
        case .biometricDisabled: return "Sblocco biometrico disattivato"
        case .vaultExported: return "Vault esportato"
        case .vaultImported: return "Vault importato"
        case .vaultDuplicated: return "Vault duplicato"
        case .vaultDeleted: return "Vault eliminato"
        case .vaultMigrated: return "Vault aggiornato al nuovo formato"
        case .filesExported: return "File esportati"
        case .filesDeleted: return "File eliminati"
        case .secureShareCreated: return "Pacchetto protetto creato"
        case .secureShareOpened: return "Pacchetto protetto aperto"
        }
    }

    var symbol: String {

        switch self {
        case .vaultCreated: return "plus.circle"
        case .unlockSucceeded: return "lock.open"
        case .unlockFailed: return "exclamationmark.lock"
        case .passwordChanged, .passwordReset: return "key"
        case .recoveryKeyCreated, .recoveryKeyRemoved: return "lifepreserver"
        case .biometricEnabled, .biometricDisabled: return "faceid"
        case .vaultExported, .filesExported: return "square.and.arrow.up"
        case .vaultImported: return "square.and.arrow.down"
        case .vaultDuplicated: return "doc.on.doc"
        case .vaultDeleted, .filesDeleted: return "trash"
        case .vaultMigrated: return "arrow.triangle.2.circlepath"
        case .secureShareCreated, .secureShareOpened: return "shippingbox"
        }
    }
}

private extension SecurityEvent.Severity {

    var color: Color {

        switch self {
        case .info: return .secondary
        case .notice: return .blue
        case .warning: return .orange
        }
    }
}

/// Registro di sicurezza: per un vault (`vault` valorizzato) oppure di tutti.
struct SecurityLogView: View {

    /// Nome (cartella) del vault; `nil` = tutti i vault.
    let vault: String?

    @Environment(\.dismiss)
    private var dismiss

    @State private var events: [SecurityEvent] = []
    @State private var summary: SecurityLog.Summary?
    @State private var confirmingClear = false

    var body: some View {

        NavigationStack {

            List {

                if let summary {
                    summarySection(summary)
                }

                Section {

                    if events.isEmpty {

                        Text("Nessun evento registrato.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(events) { event in
                        row(for: event)
                    }

                } header: {
                    Text("Cronologia")
                } footer: {
                    Text("Il registro contiene solo date ed eventi: mai password, chiavi, nomi di file o contenuti dei documenti. Resta su questo dispositivo e conserva gli ultimi 500 eventi.")
                }
            }
            .navigationTitle(vault.map { "Registro: \($0)" } ?? "Registro di sicurezza")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {

                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarLeading) {

                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(events.isEmpty)
                    .accessibilityLabel("Cancella il registro")
                }
            }
            .alert(
                "Cancellare il registro?",
                isPresented: $confirmingClear
            ) {

                Button("Cancella", role: .destructive) {
                    SecurityLog.shared.clear(vault: vault)
                    reload()
                }

                Button("Annulla", role: .cancel) {}

            } message: {
                Text("Gli eventi registrati verranno eliminati definitivamente.")
            }
            .onAppear {
                reload()
            }
        }
    }

    private func reload() {

        events = SecurityLog.shared.events(vault: vault)

        summary = vault.map { SecurityLog.shared.summary(vault: $0) }
    }

    private func summarySection(_ summary: SecurityLog.Summary) -> some View {

        Section("Riepilogo") {

            LabeledContent("Ultimo sblocco", value: text(for: summary.lastUnlock))
            LabeledContent("Ultima esportazione", value: text(for: summary.lastExport))
            LabeledContent("Ultima importazione", value: text(for: summary.lastImport))

            LabeledContent("Tentativi falliti") {

                Text("\(summary.failedAttempts)")
                    .foregroundStyle(summary.failedAttempts > 0 ? Color.orange : Color.secondary)
                    .fontWeight(summary.failedAttempts > 0 ? .semibold : .regular)
            }
        }
    }

    private func text(for date: Date?) -> String {

        guard let date else {
            return "—"
        }

        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func row(for event: SecurityEvent) -> some View {

        HStack(alignment: .top, spacing: 12) {

            Image(systemName: event.kind.symbol)
                .foregroundStyle(event.severity.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {

                Text(event.kind.title)
                    .font(.subheadline.weight(event.severity == .info ? .regular : .semibold))

                if vault == nil {

                    Text(event.vault)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let detail = event.detail, !detail.isEmpty {

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
