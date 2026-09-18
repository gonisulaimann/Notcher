import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @ObservedObject var peer: LinkPeer
    @State private var draft = ""
    @State private var showPicker = false
    @State private var shareURL: URL?
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                macTimerSection
                liveActivitySection
                sendSection
                receivedSection
                settingsSection
            }
            .navigationTitle("Notcher Link")
            .onReceive(tick) { now = $0 }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker { url in
                if let data = try? Data(contentsOf: url) {
                    peer.sendFile(name: url.lastPathComponent, data: data)
                }
            }
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(url: url.url)
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Mac") {
            HStack {
                Circle()
                    .fill(peer.peers.isEmpty ? Color.gray : Color.green)
                    .frame(width: 10, height: 10)
                Text(peer.peers.isEmpty ? "Not connected" : peer.peers.map(\.deviceName).joined(separator: ", "))
            }
            if !peer.running {
                HStack {
                    TextField("Pairing code from Mac", text: $peer.code)
                        .keyboardType(.numberPad)
                        .monospacedDigit()
                    Button("Connect") { peer.reconnect() }
                        .disabled(peer.code.count != 6)
                }
            } else {
                Button("Disconnect", role: .destructive) { peer.stop() }
            }
            if peer.helpNeeded {
                Text("Still nothing — check both devices are on the same Wi-Fi, Local Network is allowed for this app, and the 6-digit code matches the Mac island.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let m = peer.macMedia, m.playing {
                Label("\(m.title ?? "Music")\(m.artist.map { " — \($0)" } ?? "")",
                      systemImage: "music.note")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var macTimerSection: some View {
        Section("Mac timer") {
            if let t = peer.macTimer, t.isFresh {
                VStack(alignment: .leading, spacing: 6) {
                    Text(liveString(t))
                        .font(.system(.title, design: .rounded).monospacedDigit())
                    ProgressView(value: t.total > 0 ? t.liveRemaining / t.total : 0)
                    if !t.label.isEmpty {
                        Text(t.label).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Cancel on Mac", role: .destructive) { peer.cancelMacTimer() }
            } else {
                Text("No timer running on the Mac.")
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach([5, 15, 25], id: \.self) { m in
                        Button("\(m)m") { peer.startMacTimer(seconds: Double(m * 60), label: "Focus") }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var liveActivitySection: some View {
        Section("iPhone Live Activity Mirror") {
            Text("Simulate or mirror an iPhone Live Activity to the Mac dynamic island.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                peer.sendLiveActivity(
                    id: "food-delivery",
                    type: "delivery",
                    title: "Joe's Pizza",
                    subtitle: "Courier on the way • 8 mins",
                    progress: 0.65,
                    icon: "bag.fill",
                    leadingText: "Order #482",
                    trailingText: "ETA 8m"
                )
            } label: {
                Label("Start Pizza Delivery (ETA 8m)", systemImage: "bag.fill")
            }
            .disabled(peer.peers.isEmpty)

            Button {
                peer.sendLiveActivity(
                    id: "uber-ride",
                    type: "ride",
                    title: "Uber Premier",
                    subtitle: "Toyota Camry • 4 mins away",
                    progress: 0.40,
                    icon: "car.fill",
                    leadingText: "Driver En Route",
                    trailingText: "4 min"
                )
            } label: {
                Label("Start Ride Share (4 min away)", systemImage: "car.fill")
            }
            .disabled(peer.peers.isEmpty)

            Button {
                peer.sendLiveActivity(
                    id: "flight-tracker",
                    type: "flight",
                    title: "Flight BA 184",
                    subtitle: "London LHR → New York JFK",
                    progress: 0.85,
                    icon: "airplane",
                    leadingText: "Gate B22",
                    trailingText: "On Time"
                )
            } label: {
                Label("Start Flight Tracker (BA 184)", systemImage: "airplane")
            }
            .disabled(peer.peers.isEmpty)

            Button(role: .destructive) {
                peer.endLiveActivity(id: "active")
            } label: {
                Label("End Live Activity", systemImage: "xmark.circle")
            }
            .disabled(peer.peers.isEmpty)
        }
    }

    private var sendSection: some View {
        Section("Send to Mac") {
            HStack {
                TextField("Text note…", text: $draft)
                    .onSubmit(sendDraft)
                Button("Send", action: sendDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || peer.peers.isEmpty)
            }
            Button {
                showPicker = true
            } label: {
                Label(peer.receiving.map { "Receiving \($0.fileName) \($0.got)/\($0.total)…" } ?? "Send file…",
                      systemImage: "doc.badge.plus")
            }
            .disabled(peer.peers.isEmpty)
        }
    }

    private var receivedSection: some View {
        Section("From Mac") {
            if peer.texts.isEmpty, peer.files.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            }
            ForEach(peer.texts) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                    Text("\(item.peer) · \(item.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    UIPasteboard.general.string = item.text
                }
            }
            ForEach(peer.files) { item in
                Button {
                    shareURL = ShareURL(url: item.url)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text("\(item.peer) · \(item.date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            Toggle("Share battery level", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "link.shareBattery") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "link.shareBattery") }
            ))
            Text("Local Wi-Fi only · AES-GCM with your pairing code · no cloud, no account.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func sendDraft() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        peer.sendText(t)
        draft = ""
    }

    private func liveString(_ t: LinkPeer.MacTimer) -> String {
        let s = max(0, Int(t.liveRemaining.rounded()))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - UIKit bridges

private struct ShareURL: Identifiable {
    var id: URL { url }
    var url: URL
}

struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    func makeCoordinator() -> Coord { Coord(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}
    final class Coord: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            onPick(url)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_: UIViewController, context _: Context) {}
}
