import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import simd

struct ContentView: View {
    @StateObject private var scanner = RGBScanner()
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview = false
    @State private var confirmNew = false

    var body: some View {
        VStack(spacing: 12) {
            Text("LiDAR Studio · Scanner RGB 0.3").font(.headline)
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
                }.buttonStyle(.borderedProminent).disabled(!RGBScanner.supported)
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
            Text("Muoviti lentamente, con buona luce. Distanza 0,2–4 m.\nGriglia 2,5 cm · massimo 300.000 punti")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .confirmationDialog("Iniziare una nuova scansione? Esporta prima i punti da conservare.", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("Nuova scansione", role: .destructive) { scanner.start() }
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

private struct RGBVoxel: Hashable {
    let x: Int32
    let y: Int32
    let z: Int32
    init(_ p: SIMD3<Float>) {
        x = Int32(floor(p.x / 0.025))
        y = Int32(floor(p.y / 0.025))
        z = Int32(floor(p.z / 0.025))
    }
}

// Delegate callbacks and UI actions run on the main queue. No frame or pixel
// buffer is retained beyond a callback; the scan has a fixed memory bound.
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
    private let limit = 300_000

    override init() {
        super.init()
        session.delegateQueue = .main
        session.delegate = self
    }

    func start() {
        guard Self.supported, !running else { return }
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
        guard !running else { return }
        points.removeAll(keepingCapacity: true)
        voxels.removeAll(keepingCapacity: true)
        previewScene = SCNScene()
        count = 0
        exportedURL = nil
        lastTime = -1
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
            status = "Localizzazione non stabile: rallenta e inquadra superfici con dettagli."
            return
        }
        guard let depth = frame.sceneDepth else { status = "Attendo dati LiDAR…"; return }
        accumulate(frame, depth: depth)
        count = points.count
        status = "Acquisizione RGB in corso"
        if count >= limit {
            stop()
            status = "Limite di 300.000 punti raggiunto. Esporta la scansione."
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
                guard d.isFinite, d >= 0.2, d <= 4 else { continue }
                // Optical image: x right, y down, z forward. ARKit camera:
                // x right, y up, viewing direction -z. Both maps use native
                // sensor orientation; UI portrait rotation must not be applied.
                let cameraPoint = SIMD4<Float>((Float(x) - cx) * d / fx, -(Float(y) - cy) * d / fy, -d, 1)
                let world = frame.camera.transform * cameraPoint
                let p = SIMD3<Float>(world.x, world.y, world.z)
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
                      abs(p.x) < 10000, abs(p.y) < 10000, abs(p.z) < 10000 else { continue }
                guard voxels.insert(RGBVoxel(p)).inserted else { continue }
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

    func exportPLY() {
        guard !running, !points.isEmpty else { return }
        var data = Data("ply\nformat binary_little_endian 1.0\ncomment LiDAR Studio RGB 0.3; meters; Y up\nelement vertex \(points.count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n".utf8)
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
