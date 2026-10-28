import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import simd
import CoreImage

struct ContentView: View {
    @StateObject private var scanner = RGBScanner()
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview = false
    @State private var confirmNew = false
    @State private var settings = false

    var body: some View {
        VStack(spacing: 12) {
            Text("LiDAR Studio · Scanner RGB 0.3.2").font(.headline)
            RGBCameraView(session: scanner.session)
                .overlay(alignment: .topLeading) {
                    Text("\(scanner.count.formatted()) punti")
                        .padding(10).background(.ultraThinMaterial, in: Capsule()).padding()
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(scanner.status).font(.subheadline).multilineTextAlignment(.center)
            HStack {
                Button(scanner.running ? "Termina" : "Nuova scansione") {
                    if scanner.running { scanner.stop() }
                    else if scanner.count > 0 { confirmNew = true }
                    else { scanner.start() }
                }.buttonStyle(.borderedProminent).disabled(!RGBScanner.supported || scanner.datasetBusy)
                Button("Anteprima 3D") {
                    scanner.makePreview()
                    preview = true
                }.buttonStyle(.bordered).disabled(scanner.running || scanner.count == 0)
            }
            if !scanner.running && scanner.count > 0 {
                Button("Esporta PLY a colori") { scanner.exportPLY() }
                if let url = scanner.exportedURL {
                    ShareLink("Salva o condividi PLY", item: url)
                }
            }
            if !scanner.running && scanner.recordedFrames > 0 {
                Button(scanner.datasetBusy ? "Preparazione ZIP…" : "Esporta dataset RGB-D") {
                    scanner.exportDataset()
                }.disabled(scanner.datasetBusy)
                if let url = scanner.datasetURL {
                    ShareLink("Salva o condividi dataset ZIP", item: url)
                }
            }
            Text(scanner.datasetStatus).font(.caption).foregroundStyle(.secondary)
            Button("Impostazioni scansione") { settings = true }
                .disabled(scanner.running)
            Text("\(scanner.scanSummary)\nEpisodi di tracking limitato: \(scanner.trackingLosses)")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .confirmationDialog("Iniziare una nuova scansione? Esporta prima PLY e dataset da conservare.", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("Nuova scansione", role: .destructive) { scanner.start() }
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                Form {
                    Toggle("Registra dataset RGB-D", isOn: $scanner.datasetEnabled)
                    Text("Circa 1 foto/s, massimo 60. Salva RGB, profondità e pose per analizzare il disallineamento. Dopo Termina esporta lo ZIP e salvalo in File.")
                    Picker("Densità", selection: $scanner.density) {
                        ForEach(RGBDensity.allCases) { density in
                            Text(density.rawValue).tag(density)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Distanza massima: \(scanner.maxDistance, specifier: "%.1f") m")
                        Slider(value: $scanner.maxDistance, in: 1...4, step: 0.5)
                    }
                    Text("Per la scrivania: griglia 1 cm, distanza massima 2 m. Una griglia più fine aumenta punti, memoria e tempi; non aumenta la precisione del LiDAR.")
                    Text("Muoviti lentamente di lato, mantenendo superfici con dettagli nell’inquadratura. Evita rotazioni brusche. La densità non corregge la deriva o le superfici sdoppiate.")
                }
                .navigationTitle("Acquisizione")
                .toolbar { Button("Fine") { settings = false } }
            }
        }
        .sheet(isPresented: $preview) {
            NavigationStack {
                SceneView(scene: scanner.previewScene, options: [.allowsCameraControl])
                    .navigationTitle("Nuvola RGB")
                    .toolbar { Button("Chiudi") { preview = false } }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { scanner.stop() }
        }
        .onDisappear { scanner.stop() }
    }
}

private struct RGBCameraView: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        return view
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

private struct RGBPoint {
    let position: SIMD3<Float>
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

private enum RGBDensity: String, CaseIterable, Identifiable {
    case standard = "Standard · 2,5 cm"
    case fine = "Fine · 1 cm"
    var id: String { rawValue }
    var voxelSize: Float { self == .fine ? 0.01 : 0.025 }
    var pointLimit: Int { self == .fine ? 600_000 : 300_000 }
}

private struct RGBVoxel: Hashable {
    let x: Int32
    let y: Int32
    let z: Int32
    init(_ p: SIMD3<Float>, size: Float) {
        x = Int32(floor(p.x / size))
        y = Int32(floor(p.y / size))
        z = Int32(floor(p.z / size))
    }
}

// UI and AR callbacks use the main queue. Dataset writing uses a serial
// worker with at most one pending RGB/depth/confidence buffer set.
private final class RGBScanner: NSObject, ObservableObject, ARSessionDelegate {
    static var supported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }
    let session = ARSession()
    @Published private(set) var running = false
    @Published private(set) var count = 0
    @Published private(set) var status = supported ? "Pronto per acquisire LiDAR + RGB" : "Serve un iPhone o iPad con LiDAR."
    @Published private(set) var exportedURL: URL?
    private(set) var previewScene = SCNScene()
    private var points: [RGBPoint] = []
    private var voxels: Set<RGBVoxel> = []
    private var lastTime: TimeInterval = -1
    @Published var density: RGBDensity = .fine
    @Published var maxDistance: Double = 2
    @Published private(set) var trackingLosses = 0
    @Published var datasetEnabled = true
    @Published private(set) var recordedFrames = 0
    @Published private(set) var datasetURL: URL?
    @Published private(set) var datasetBusy = false
    @Published private(set) var datasetStatus = "Dataset RGB-D: pronto, fino a 60 fotogrammi"
    private var recorder: RGBDRecorder?
    private var activeDensity: RGBDensity = .fine
    private var activeDistance: Float = 2
    private var stableSince: TimeInterval?
    private var trackingWasLimited = false
    private var limit: Int { activeDensity.pointLimit }
    var scanSummary: String {
        let selected = count > 0 || running ? activeDensity : density
        let distance = count > 0 || running ? Double(activeDistance) : maxDistance
        return "\(selected.rawValue) · 0,2–\(String(format: "%.1f", distance)) m"
    }

    override init() {
        super.init()
        session.delegateQueue = .main
        session.delegate = self
    }

    func start() {
        guard Self.supported, !running, !datasetBusy else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.begin() }
                    else { self?.status = "Consenti la fotocamera nelle Impostazioni dell’iPhone." }
                }
            }
        default: status = "Consenti la fotocamera nelle Impostazioni dell’iPhone."
        }
    }

    private func begin() {
        guard !running, !datasetBusy else { return }
        do {
            if datasetEnabled {
                recorder = try RGBDRecorder(voxel: density.voxelSize, maxDepth: Float(maxDistance))
            } else {
                recorder = nil
            }
        } catch {
            status = "Impossibile preparare il dataset: \(error.localizedDescription)"
            return
        }
        datasetURL = nil
        recordedFrames = 0
        datasetStatus = datasetEnabled ? "Dataset: registrazione attiva, massimo 60 fotogrammi" : "Dataset: disattivato"
        points.removeAll(keepingCapacity: true)
        voxels.removeAll(keepingCapacity: true)
        previewScene = SCNScene()
        count = 0
        exportedURL = nil
        lastTime = -1
        activeDensity = density
        activeDistance = Float(maxDistance)
        trackingLosses = 0
        trackingWasLimited = false
        stableSince = nil
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = .sceneDepth
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        running = true
        status = "Inizializzazione: inquadra superfici con dettagli."
    }

    func stop() {
        guard running else { return }
        running = false
        session.pause()
        status = count == 0 ? "Nessun punto acquisito. Riprova con più luce." : "Scansione terminata: \(count.formatted()) punti."
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running, frame.timestamp - lastTime >= 0.2 else { return }
        lastTime = frame.timestamp
        guard case .normal = frame.camera.trackingState else {
            if !trackingWasLimited { trackingLosses += 1 }
            trackingWasLimited = true
            stableSince = nil
            status = "Localizzazione non stabile: rallenta e inquadra superfici con dettagli."
            return
        }
        trackingWasLimited = false
        if stableSince == nil { stableSince = frame.timestamp }
        guard let stableSince, frame.timestamp - stableSince >= 0.6 else {
            status = "Attendo tracking stabile…"
            return
        }
        guard let depth = frame.sceneDepth else { status = "Attendo dati LiDAR…"; return }
        if let recorder {
            recorder.capture(frame, depth: depth, trackingLosses: trackingLosses) { [weak self, weak recorder] result in
                guard let self, let recorder, self.recorder === recorder else { return }
                switch result {
                case .success(let saved):
                    self.recordedFrames = saved
                    self.datasetStatus = "Dataset: \(saved)/60 fotogrammi salvati"
                case .failure(let error):
                    self.datasetStatus = "Registrazione dataset fermata: \(error.localizedDescription). Esporta i fotogrammi già salvati."
                }
            }
        }
        accumulate(frame, depth: depth)
        count = points.count
        status = "Acquisizione RGB in corso"
        if count >= limit {
            stop()
            status = "Limite di \(limit.formatted()) punti raggiunto. Esporta la scansione."
        }
    }

    private func accumulate(_ frame: ARFrame, depth: ARDepthData) {
        let map = depth.depthMap
        let image = frame.capturedImage
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPlaneCount(image) == 2 else { return }
        let format = CVPixelBufferGetPixelFormatType(image)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        let confidence = depth.confidenceMap
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer {
            if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(map),
              let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let iw = CVPixelBufferGetWidthOfPlane(image, 0), ih = CVPixelBufferGetHeightOfPlane(image, 0)
        let uw = CVPixelBufferGetWidthOfPlane(image, 1), uh = CVPixelBufferGetHeightOfPlane(image, 1)
        let depthStride = CVPixelBufferGetBytesPerRow(map)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let k = frame.camera.intrinsics
        let sx = Float(w) / Float(frame.camera.imageResolution.width)
        let sy = Float(h) / Float(frame.camera.imageResolution.height)
        let fx = k[0][0] * sx, fy = k[1][1] * sy
        let cx = k[2][0] * sx, cy = k[2][1] * sy
        let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        for y in stride(from: 0, to: h, by: 2) {
            let row = depthBase.advanced(by: y * depthStride).assumingMemoryBound(to: Float32.self)
            for x in stride(from: 0, to: w, by: 2) {
                if points.count >= limit { return }
                if let confidence, let base = CVPixelBufferGetBaseAddress(confidence) {
                    let cw = CVPixelBufferGetWidth(confidence), ch = CVPixelBufferGetHeight(confidence)
                    let offset = min(ch - 1, y * ch / h) * CVPixelBufferGetBytesPerRow(confidence) + min(cw - 1, x * cw / w)
                    if base.load(fromByteOffset: offset, as: UInt8.self) < 2 { continue }
                }
                let d = row[x]
                guard d.isFinite, d >= 0.2, d <= activeDistance else { continue }
                // Optical image: x right, y down, z forward. ARKit camera:
                // x right, y up, viewing direction -z. Both maps use native
                // sensor orientation; UI portrait rotation must not be applied.
                let cameraPoint = SIMD4<Float>((Float(x) - cx) * d / fx, -(Float(y) - cy) * d / fy, -d, 1)
                let world = frame.camera.transform * cameraPoint
                let p = SIMD3<Float>(world.x, world.y, world.z)
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
                      abs(p.x) < 10000, abs(p.y) < 10000, abs(p.z) < 10000 else { continue }
                guard voxels.insert(RGBVoxel(p, size: activeDensity.voxelSize)).inserted else { continue }
                let ix = min(iw - 1, Int((Float(x) + 0.5) * Float(iw) / Float(w)))
                let iy = min(ih - 1, Int((Float(y) + 0.5) * Float(ih) / Float(h)))
                let ux = min(uw - 1, ix * uw / iw), uy = min(uh - 1, iy * uh / ih)
                var yy = Float(yBase.load(fromByteOffset: iy * yStride + ix, as: UInt8.self))
                var cb = Float(uvBase.load(fromByteOffset: uy * uvStride + ux * 2, as: UInt8.self)) - 128
                var cr = Float(uvBase.load(fromByteOffset: uy * uvStride + ux * 2 + 1, as: UInt8.self)) - 128
                if !full { yy = (yy - 16) * 255 / 219; cb *= 255 / 224; cr *= 255 / 224 }
                func byte(_ value: Float) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
                points.append(RGBPoint(position: p, r: byte(yy + 1.402 * cr),
                                       g: byte(yy - 0.344136 * cb - 0.714136 * cr), b: byte(yy + 1.772 * cb)))
            }
        }
    }

    func makePreview() {
        guard !running, !points.isEmpty else { return }
        let scene = SCNScene()
        scene.background.contents = UIColor.black
        var vertices: [SCNVector3] = []
        var colors: [Float] = []
        var low = points[0].position, high = low
        // Preview is sampled to bound rendering cost; PLY keeps all points.
        let step = max(1, Int(ceil(Double(points.count) / 100_000)))
        for i in stride(from: 0, to: points.count, by: step) {
            let p = points[i]
            low = simd_min(low, p.position); high = simd_max(high, p.position)
            vertices.append(SCNVector3(p.position.x, p.position.y, p.position.z))
            colors += [Float(p.r) / 255, Float(p.g) / 255, Float(p.b) / 255, 1]
        }
        let colorSource = SCNGeometrySource(data: colors.withUnsafeBytes { Data($0) }, semantic: .color,
            vectorCount: vertices.count, usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let indices = (0..<vertices.count).map { UInt32($0) }
        let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) }, primitiveType: .point,
            primitiveCount: indices.count, bytesPerIndex: 4)
        element.pointSize = 3; element.minimumPointScreenSpaceRadius = 1; element.maximumPointScreenSpaceRadius = 4
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        let center = (low + high) / 2
        node.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(node)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 1000
        camera.position = SCNVector3(0, 0, max(1, simd_length(high - low) * 1.5))
        scene.rootNode.addChildNode(camera)
        previewScene = scene
    }

    func exportDataset() {
        guard !running, !datasetBusy, let recorder else { return }
        datasetBusy = true
        datasetURL = nil
        datasetStatus = "Preparazione dataset ZIP…"
        recorder.export(trackingLosses: trackingLosses) { [weak self] result in
            guard let self else { return }
            self.datasetBusy = false
            switch result {
            case .success(let url):
                self.datasetURL = url
                self.datasetStatus = "Dataset pronto: usa Salva o condividi dataset ZIP."
            case .failure(let error):
                self.datasetStatus = "Esportazione dataset fallita: \(error.localizedDescription)"
            }
        }
    }

    func exportPLY() {
        guard !running, !points.isEmpty else { return }
        var data = Data("ply\nformat binary_little_endian 1.0\ncomment LiDAR Studio RGB 0.3.2; meters; Y up\ncomment voxel_m \(activeDensity.voxelSize); max_depth_m \(activeDistance); tracking_interruptions \(trackingLosses)\nelement vertex \(points.count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n".utf8)
        data.reserveCapacity(data.count + points.count * 15)
        for p in points {
            for f in [p.position.x, p.position.y, p.position.z] {
                var bits = f.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: [p.r, p.g, p.b])
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RGB-\(UUID().uuidString.prefix(8)).ply")
        do {
            try data.write(to: url, options: .atomic)
            exportedURL = url
            status = "PLY pronto: usa Salva o condividi per conservarlo in File."
        } catch { status = "Esportazione fallita: \(error.localizedDescription)" }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        stop()
        status = "Errore AR: \(error.localizedDescription). Avvia una nuova scansione."
    }
    func sessionWasInterrupted(_ session: ARSession) {
        stop()
        status = "Sessione interrotta. Puoi esportare i punti raccolti."
    }
}

private func datasetError(_ message: String) -> NSError {
    NSError(domain: "LiDARStudioRGB.Dataset", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

private final class RGBDRecorder {
    private let queue = DispatchQueue(label: "LiDARStudioRGB.dataset", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let directory: URL
    private let voxel: Float
    private let maxDepth: Float
    // Main queue only.
    private var pending = false
    private var failed = false
    private var lastTimestamp: TimeInterval = -1
    private var submitted = 0
    // Worker queue only.
    private var frames: [[String: Any]] = []
    private var captureError: String?

    init(voxel: Float, maxDepth: Float) throws {
        self.voxel = voxel
        self.maxDepth = maxDepth
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RGBD-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        let url = directory
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    // Input buffers belong to one ARFrame. Retain only buffers, not ARFrame.
    func capture(_ frame: ARFrame, depth: ARDepthData, trackingLosses: Int,
                 completion: @escaping (Result<Int, Error>) -> Void) {
        guard !pending, !failed, submitted < 60,
              lastTimestamp < 0 || frame.timestamp - lastTimestamp >= 1 else { return }
        guard CVPixelBufferGetPixelFormatType(depth.depthMap) == kCVPixelFormatType_DepthFloat32 else { return }
        pending = true
        lastTimestamp = frame.timestamp
        let index = submitted
        submitted += 1
        let image = frame.capturedImage
        let map = depth.depthMap
        let confidence = depth.confidenceMap
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        let dw = CVPixelBufferGetWidth(map), dh = CVPixelBufferGetHeight(map)
        let transform = frame.camera.transform
        let k = frame.camera.intrinsics
        var dk = k
        let sx = Float(dw) / Float(frame.camera.imageResolution.width)
        let sy = Float(dh) / Float(frame.camera.imageResolution.height)
        for column in 0..<3 { dk[column][0] *= sx; dk[column][1] *= sy }
        let stem = String(format: "frame_%04d", index)
        func matrix3(_ m: simd_float3x3) -> [[Float]] {
            (0..<3).map { c in [m[c][0], m[c][1], m[c][2]] }
        }
        let metadata: [String: Any] = [
            "index": index, "timestamp_seconds": frame.timestamp,
            "rgb": "\(stem)/rgb.jpg", "depth": "\(stem)/depth.f32",
            "image_width": w, "image_height": h, "depth_width": dw, "depth_height": dh,
            "intrinsics_columns": matrix3(k), "depth_intrinsics_columns": matrix3(dk),
            "camera_to_world_columns": (0..<4).map { c in
                [transform[c][0], transform[c][1], transform[c][2], transform[c][3]]
            },
            "tracking": "normal", "tracking_limited_episodes": trackingLosses,
            "world_mapping_status_raw": frame.worldMappingStatus.rawValue
        ]
        queue.async { [self] in
            let folder = directory.appendingPathComponent(stem, isDirectory: true)
            do {
                let saved: Int = try autoreleasepool {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let ciImage = CIImage(cvPixelBuffer: image)
                    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent),
                          let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) else {
                        throw datasetError("Impossibile codificare la fotografia RGB.")
                    }
                    try jpeg.write(to: folder.appendingPathComponent("rgb.jpg"), options: .atomic)
                    try Self.packedDepth(map).write(to: folder.appendingPathComponent("depth.f32"), options: .atomic)
                    var record = metadata
                    if let confidence {
                        try Self.packedConfidence(confidence).write(to: folder.appendingPathComponent("confidence.u8"), options: .atomic)
                        record["confidence"] = "\(stem)/confidence.u8"
                        record["confidence_width"] = CVPixelBufferGetWidth(confidence)
                        record["confidence_height"] = CVPixelBufferGetHeight(confidence)
                    }
                    let json = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                    try json.write(to: folder.appendingPathComponent("frame.json"), options: .atomic)
                    frames.append(record)
                    return frames.count
                }
                DispatchQueue.main.async { [self] in
                    pending = false
                    completion(.success(saved))
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                captureError = error.localizedDescription
                DispatchQueue.main.async { [self] in
                    pending = false
                    failed = true
                    completion(.failure(error))
                }
            }
        }
    }

    private static func packedDepth(_ buffer: CVPixelBuffer) throws -> Data {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw datasetError("Impossibile leggere la profondità.")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw datasetError("Profondità assente.") }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var result = Data(capacity: w * h * 4)
        for y in 0..<h {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float32.self)
            for x in 0..<w {
                var bits = row[x].bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) }
            }
        }
        return result
    }

    private static func packedConfidence(_ buffer: CVPixelBuffer) throws -> Data {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw datasetError("Formato confidence non supportato.")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw datasetError("Confidence assente.") }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var result = Data(capacity: w * h)
        for y in 0..<h {
            result.append(base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self), count: w)
        }
        return result
    }

    func export(trackingLosses: Int, completion: @escaping (Result<URL, Error>) -> Void) {
        // Serial queue: any in-flight frame completes before manifest/export.
        queue.async { [self] in
            var output: URL?
            do {
                guard !frames.isEmpty else { throw datasetError("Nessun fotogramma salvato.") }
                var manifest: [String: Any] = [
                    "schema": "lidar-studio-rgbd-1", "app_version": "0.3.2",
                    "frame_count": frames.count, "frames": frames,
                    "units": "meters", "depth_format": "float32_little_endian_row_major_no_padding",
                    "confidence_format": "uint8_row_major_no_padding_0_low_1_medium_2_high",
                    "image_orientation": "native_sensor_pixels_no_UI_rotation",
                    "matrix_layout": "array_of_columns",
                    "camera_axes": "ARKit: x right, y up, forward -z",
                    "world_axes": "ARKit world, Y up; origin reset at scan start",
                    "unprojection": "u,v native depth pixels; X=(u-cx)*d/fx, Y=-(v-cy)*d/fy, Z=-d; world=camera_to_world*[X,Y,Z,1]",
                    "depth_values": "raw sceneDepth; reject nonfinite or <=0; apply confidence and distance filters when processing",
                    "cloud_voxel_m": voxel, "cloud_max_depth_m": maxDepth,
                    "cloud_min_depth_m": 0.2, "cloud_min_confidence": 2,
                    "tracking_limited_episodes": trackingLosses,
                    "sample_interval_seconds": 1.0, "max_frames": 60,
                    "note": "Dataset frames are a subset of the frames accumulated into the separately exported PLY. Poses are not refined."
                ]
                if let captureError { manifest["capture_error"] = captureError }
                let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                try json.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Dataset-RGBD-\(UUID().uuidString.prefix(8)).zip")
                output = url
                try RGBDZip.write(directory: directory, output: url)
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                if let output { try? FileManager.default.removeItem(at: output) }
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}

// ZIP32 with stored entries: one file in memory at a time, no dependencies.
private enum RGBDZip {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    static func write(directory: URL, output: URL) throws {
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw datasetError("Impossibile elencare il dataset.")
        }
        var files: [URL] = []
        for case let url as URL in iterator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(url) }
        }
        files.sort { $0.path < $1.path }
        guard files.count < 65535, FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw datasetError("Impossibile creare lo ZIP.")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var central = Data()
        for file in files {
            try autoreleasepool {
                let relative = file.pathComponents.dropFirst(directory.pathComponents.count).joined(separator: "/")
                let name = Data(relative.utf8)
                let body = try Data(contentsOf: file)
                let offset = try handle.offset()
                guard name.count < 65535, body.count < Int(UInt32.max), offset < UInt64(UInt32.max) else {
                    throw datasetError("Dataset troppo grande per ZIP32.")
                }
                let size = UInt32(body.count), crc = crc32(body)
                var local = Data()
                append(UInt32(0x04034b50), to: &local)
                for v in [UInt16(20), 0x0800, 0, 0, 33] { append(v, to: &local) }
                for v in [crc, size, size] { append(v, to: &local) }
                append(UInt16(name.count), to: &local); append(UInt16(0), to: &local)
                local.append(name)
                try handle.write(contentsOf: local); try handle.write(contentsOf: body)
                append(UInt32(0x02014b50), to: &central)
                for v in [UInt16(20), 20, 0x0800, 0, 0, 33] { append(v, to: &central) }
                for v in [crc, size, size] { append(v, to: &central) }
                for v in [UInt16(name.count), 0, 0, 0, 0] { append(v, to: &central) }
                append(UInt32(0), to: &central); append(UInt32(offset), to: &central)
                central.append(name)
            }
        }
        let start = try handle.offset()
        guard start + UInt64(central.count) < UInt64(UInt32.max) else { throw datasetError("Limite ZIP32 superato.") }
        try handle.write(contentsOf: central)
        var end = Data()
        append(UInt32(0x06054b50), to: &end)
        for v in [UInt16(0), 0, UInt16(files.count), UInt16(files.count)] { append(v, to: &end) }
        append(UInt32(central.count), to: &end); append(UInt32(start), to: &end)
        append(UInt16(0), to: &end)
        try handle.write(contentsOf: end)
    }
}
