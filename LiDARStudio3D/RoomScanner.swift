import Foundation
import RoomPlan
import SwiftUI

/// The scanning controller shared by SwiftUI and the UIKit-based RoomPlan view.
@MainActor
final class RoomScanner: NSObject, ObservableObject, RoomCaptureViewDelegate {
    @Published private(set) var isScanning = false
    @Published private(set) var exportedURL: URL?
    @Published private(set) var status = "Pronto per una nuova scansione"

    let captureView = RoomCaptureView(frame: .zero)

    override init() {
        super.init()
        captureView.delegate = self
        captureView.isModelEnabled = true
    }

    func start() {
        guard RoomCaptureSession.isSupported else {
            status = "Questo dispositivo non supporta RoomPlan e LiDAR."
            return
        }
        guard !isScanning else { return }
        exportedURL = nil
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        isScanning = true
        status = "Scansione in corso: muovi lentamente l’iPhone lungo le pareti."
    }

    func stop() {
        guard isScanning else { return }
        captureView.captureSession.stop()
        isScanning = false
        status = "Elaborazione del modello 3D in corso…"
    }

    // RoomCaptureView handles processing and previews the final reconstructed room.
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            status = "Errore di scansione: \(error.localizedDescription)"
            return false
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            status = "Errore di elaborazione: \(error.localizedDescription)"
            return
        }

        // Keep exported models in Documents, so ShareLink can access them.
        let filename = "Scansione-\(UUID().uuidString.prefix(8)).usdz"
        let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        do {
            try processedResult.export(to: fileURL)
            exportedURL = fileURL
            status = "Modello pronto! Puoi visualizzarlo e condividerlo."
        } catch {
            status = "Impossibile esportare il modello: \(error.localizedDescription)"
        }
    }     // Metodi richiesti dal protocollo NSCoding
    nonisolated required init?(coder: NSCoder) {
        return nil
    }

    nonisolated func encode(with coder: NSCoder) {
        // RoomScanner non viene archiviato.
    }
}
