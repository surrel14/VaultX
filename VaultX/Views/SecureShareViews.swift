import SwiftUI
import UIKit
import QuickLook

// MARK: - Create a protected package

/// Condivisione sicura di un singolo file: pacchetto `.vaultxshare` protetto da password,
/// con scadenza opzionale.
struct SecureShareView: View {

    let session: VaultSession

    let item: VaultItem

    /// Chiamata con il pacchetto creato (da condividere con AirDrop, File, altre app).
    let onCreated: (URL) -> Void

    @Environment(\.dismiss)
    private var dismiss

    enum Expiry: String, CaseIterable, Identifiable {

        case never
        case day
        case week
        case month
        case custom

        var id: String { rawValue }

        var title: String {

            switch self {
            case .never: return "Mai"
            case .day: return "Tra 24 ore"
            case .week: return "Tra 7 giorni"
            case .month: return "Tra 30 giorni"
            case .custom: return "Data personalizzata"
            }
        }
    }

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var expiry = Expiry.never
    @State private var customDate = Date().addingTimeInterval(7 * 86_400)
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingError = false

    private var canCreate: Bool {

        password.count >= 8
            && password == confirmPassword
            && !isWorking
    }

    private var expiryDate: Date? {

        switch expiry {
        case .never: return nil
        case .day: return Date().addingTimeInterval(86_400)
        case .week: return Date().addingTimeInterval(7 * 86_400)
        case .month: return Date().addingTimeInterval(30 * 86_400)
        case .custom: return customDate
        }
    }

    var body: some View {

        NavigationStack {

            Form {

                Section {

                    Label(item.name, systemImage: VaultItemRow.symbol(for: item))

                } header: {
                    Text("File")
                }

                Section {

                    SecureField("Password del pacchetto", text: $password)
                        .textContentType(.newPassword)

                    SecureField("Conferma password", text: $confirmPassword)
                        .textContentType(.newPassword)

                    PasswordStrengthView(password: password)

                } header: {
                    Text("Protezione")
                } footer: {
                    Text("Comunica la password al destinatario con un altro canale. Il file nel pacchetto è cifrato con una chiave derivata da questa password, indipendente da quella del vault.")
                }

                Section {

                    Picker("Scadenza", selection: $expiry) {

                        ForEach(Expiry.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }

                    if expiry == .custom {

                        DatePicker(
                            "Scade il",
                            selection: $customDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }

                } footer: {
                    Text("Dopo la scadenza VaultX rifiuta di aprire il pacchetto. È una cortesia, non una garanzia: non può cancellare né impedire l'uso di copie già ricevute.")
                }

                Section {

                    Button {
                        create()
                    } label: {

                        HStack {

                            Spacer()

                            if isWorking {
                                ProgressView()
                            } else {
                                Text("Crea pacchetto")
                                    .fontWeight(.semibold)
                            }

                            Spacer()
                        }
                    }
                    .disabled(!canCreate)
                }
            }
            .navigationTitle("Condividi in modo sicuro")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWorking)
            .toolbar {

                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        dismiss()
                    }
                    .disabled(isWorking)
                }
            }
            .alert("Errore", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func create() {

        guard canCreate else {
            return
        }

        isWorking = true

        let currentSession = session
        let currentItem = item
        let enteredPassword = password
        let expiresAt = expiryDate

        Task { @MainActor in

            do {

                let package = try await Task.detached(
                    priority: .userInitiated
                ) { () -> URL in

                    // Copia in chiaro temporanea: eliminata (sovrascrivendola) subito dopo.
                    let plain = try currentSession.decryptToTemporaryFile(currentItem.url)

                    defer {
                        try? SecureDelete.remove(at: plain.deletingLastPathComponent())
                    }

                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("VaultXShare", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)

                    try FileManager.default.createDirectory(
                        at: folder,
                        withIntermediateDirectories: true
                    )

                    // Nome generico: il nome del file originale non deve trapelare dal nome del pacchetto.
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd HH.mm"

                    let destination = folder.appendingPathComponent(
                        "VaultX \(formatter.string(from: Date())).\(SharePackage.fileExtension)"
                    )

                    try SharePackage.create(
                        from: plain,
                        name: currentItem.name,
                        password: enteredPassword,
                        expiresAt: expiresAt,
                        to: destination
                    )

                    return destination

                }.value

                SecurityLog.shared.record(
                    .secureShareCreated,
                    vault: session.vaultURL.lastPathComponent,
                    detail: expiresAt == nil ? "Senza scadenza" : "Con scadenza"
                )

                isWorking = false

                onCreated(package)

                dismiss()

            } catch {

                isWorking = false

                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}

// MARK: - Open a protected package

struct OpenSharePackageView: View {

    let url: URL

    @Environment(\.dismiss)
    private var dismiss

    @State private var info: SharePackage.Info?
    @State private var infoError: String?
    @State private var password = ""
    @State private var isWorking = false
    @State private var opened: (metadata: SharePackage.Metadata, fileURL: URL)?
    @State private var previewURL: URL?
    @State private var shareItem: VaultShareItem?
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {

        NavigationStack {

            Form {

                if let opened {
                    openedSections(opened)
                } else {
                    lockedSections
                }
            }
            .navigationTitle("Pacchetto protetto")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWorking)
            .toolbar {

                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") {
                        close()
                    }
                    .disabled(isWorking)
                }
            }
            .quickLookPreview($previewURL)
            .background {

                ZStack {

                    Color.clear
                        .sheet(item: $shareItem) { item in

                            ActivityView(urls: item.urls)
                                .presentationDetents([.medium, .large])
                        }

                    Color.clear
                        .alert("Errore", isPresented: $showingError) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text(errorMessage ?? "")
                        }
                }
                .allowsHitTesting(false)
            }
            .onAppear {
                loadInfo()
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var lockedSections: some View {

        if let infoError {

            Section {
                Label(infoError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

        } else {

            Section {

                if let expiresAt = info?.expiresAt {

                    Label(
                        info?.isExpired == true
                            ? "Scaduto il \(expiresAt.formatted(date: .long, time: .shortened))"
                            : "Scade il \(expiresAt.formatted(date: .long, time: .shortened))",
                        systemImage: info?.isExpired == true ? "clock.badge.xmark" : "clock"
                    )
                    .foregroundStyle(info?.isExpired == true ? Color.red : Color.secondary)

                } else {

                    Label("Nessuna scadenza", systemImage: "infinity")
                        .foregroundStyle(.secondary)
                }
            }

            Section {

                SecureField("Password del pacchetto", text: $password)
                    .textContentType(.password)

            } footer: {
                Text("La password te l'ha comunicata chi ha creato il pacchetto.")
            }

            Section {

                Button {
                    openPackage()
                } label: {

                    HStack {

                        Spacer()

                        if isWorking {
                            ProgressView()
                        } else {
                            Text("Apri")
                                .fontWeight(.semibold)
                        }

                        Spacer()
                    }
                }
                .disabled(password.isEmpty || isWorking || info?.isExpired == true)
            }
        }
    }

    @ViewBuilder
    private func openedSections(
        _ opened: (metadata: SharePackage.Metadata, fileURL: URL)
    ) -> some View {

        Section {

            Label(opened.metadata.name, systemImage: "doc")

            LabeledContent(
                "Dimensione",
                value: ByteCountFormatter.string(
                    fromByteCount: opened.metadata.size,
                    countStyle: .file
                )
            )

        } header: {
            Text("File decifrato")
        } footer: {
            Text("La copia decifrata è temporanea e viene eliminata alla chiusura.")
        }

        Section {

            Button {
                previewURL = opened.fileURL
            } label: {
                Label("Anteprima", systemImage: "eye")
            }

            Button {
                shareItem = VaultShareItem(urls: [opened.fileURL])
            } label: {
                Label("Condividi o salva…", systemImage: "square.and.arrow.up")
            }
        }
    }

    // MARK: Actions

    private func loadInfo() {

        do {
            info = try SharePackage.inspect(url)
        } catch {
            infoError = error.localizedDescription
        }
    }

    private func openPackage() {

        guard !password.isEmpty, !isWorking else {
            return
        }

        isWorking = true

        let package = url
        let entered = password

        Task { @MainActor in

            do {

                let result = try await Task.detached(
                    priority: .userInitiated
                ) {
                    try SharePackage.open(package, password: entered)
                }.value

                SecurityLog.shared.record(.secureShareOpened, vault: "—")

                isWorking = false
                password = ""
                opened = result

            } catch {

                isWorking = false

                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func close() {

        // Elimina la copia decifrata (dopo un po': un'altra app potrebbe ancora leggerla)
        // e la copia ricevuta da "Apri con…" se è nostra.
        if VaultSession.isDisposableCopy(url) {
            try? SecureDelete.remove(at: url)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            VaultSession.removeTemporaryFiles()
        }

        dismiss()
    }
}
