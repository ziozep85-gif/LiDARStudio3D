import SwiftUI
import RoomPlan

struct ContentView: View {
    @StateObject private var scanner = RoomScanner()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                RoomCaptureContainer(captureView: scanner.captureView)
                    .background(Color.black)
                    .ignoresSafeArea(edges: .top)

                Text("LiDAR Studio 3D")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.top, 12)
            }

            VStack(spacing: 14) {
                Text(scanner.status)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("scanStatus")

                Button(action: {
                    scanner.isScanning ? scanner.stop() : scanner.start()
                }) {
                    Label(scanner.isScanning ? "Termina scansione" : "Inizia scansione",
                          systemImage: scanner.isScanning ? "stop.circle.fill" : "viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!RoomCaptureSession.isSupported)
                .accessibilityIdentifier("scanButton")

                if let url = scanner.exportedURL {
                    ShareLink(item: url) {
                        Label("Esporta modello USDZ", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(8)
                    }
                    .buttonStyle(.bordered)
                }

                if !RoomCaptureSession.isSupported {
                    Text("Per questa funzione serve un iPhone o iPad compatibile con RoomPlan.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(18)
            .background(.regularMaterial)
        }
        .background(Color.black)
        .onDisappear { scanner.stop() }
    }
}

/// Embeds Apple's native room-scanning interface in SwiftUI.
private struct RoomCaptureContainer: UIViewRepresentable {
    let captureView: RoomCaptureView

    func makeUIView(context: Context) -> RoomCaptureView { captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
