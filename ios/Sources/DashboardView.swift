import SwiftUI
import WebKit

struct DashboardView: View {
    @ObservedObject var receiver: TelemetryReceiver
    @State private var showingSettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            DashboardWebView(receiver: receiver).ignoresSafeArea()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.75), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 1))
            }
            .padding(.top, 8)
            .padding(.trailing, 10)
            .accessibilityLabel("Telemetry settings")
        }
        .sheet(isPresented: $showingSettings) {
            ReceiverSettingsView(receiver: receiver)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct DashboardWebView: UIViewRepresentable {
    @ObservedObject var receiver: TelemetryReceiver

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: "window.FERMAXO_NATIVE = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = true
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        if let html = Bundle.main.url(forResource: "index", withExtension: "html") {
            view.loadFileURL(html, allowingReadAccessTo: Bundle.main.bundleURL)
        }
        receiver.onSnapshot = { [weak view] snapshot in
            guard let view else { return }
            guard JSONSerialization.isValidJSONObject(snapshot),
                  let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.fragmentsAllowed, .sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                view.evaluateJavaScript("window.FermaxoRender && window.FermaxoRender(\(json));")
            }
        }
        receiver.sendCurrent()
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private struct ReceiverSettingsView: View {
    @ObservedObject var receiver: TelemetryReceiver
    @Environment(\.dismiss) private var dismiss
    @State private var portText = "20777"

    var body: some View {
        NavigationStack {
            Form {
                Section("PlayStation connection") {
                    LabeledContent("iPhone IP", value: receiver.localIPv4 ?? "Connect to Wi-Fi")
                    LabeledContent("Fermaxo API", value: receiver.apiBaseURL ?? "Waiting for Wi-Fi")
                    Text("GET /api/telemetry · /api/health · /api/openapi.json")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    LabeledContent("API server", value: receiver.apiStatus)
                    TextField("UDP port", text: $portText)
                        .keyboardType(.numberPad)
                    LabeledContent("Receiver", value: receiver.status)
                }
                Section("F1 25 · 2026 Season Pack") {
                    Text("On PS5: UDP Telemetry ON · Broadcast OFF · IP = iPhone IP · Port = \(portText) · Send Rate = 20 Hz · UDP Format = 2026")
                    Text("Keep Fermaxo open while driving. The PS5 and iPhone must use the same Wi-Fi.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button(receiver.isListening ? "Restart UDP receiver" : "Start UDP receiver") {
                        let port = UInt16(portText) ?? 20777
                        receiver.start(port: port)
                    }
                    .disabled(UInt16(portText) == nil)
                }
            }
            .navigationTitle("FERMAXO · CONNECTION")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("DONE") { dismiss() }
                }
            }
            .onAppear { portText = String(receiver.port) }
        }
    }
}
