//
//  RoomSweepView.swift
//  AssetOnBoard
//
//  The viewfinder for a video sweep: walk the room, watch the count rise.
//

import SwiftUI
import ARKit
import AVFoundation
import Combine
import RealityKit

struct RoomSweepView: View {
    let sweeper: RoomVideoSweeper
    let scanner: RoomScanner
    let networkScanner: NetworkScanner
    let roomName: String
    let store: RoomStore
    /// The room being swept. Nil means a new one, named by `roomName`.
    let existingRoomID: UUID?
    /// Called once the sweep has been recorded, so the sheet can dismiss.
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// Drives the elapsed-time readout, which nothing else would republish.
    @State private var tick = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SweepPreview(arView: sweeper.arView,
                         boxes: sweeper.overlayBoxes,
                         orientation: sweeper.deviceOrientation)
                .ignoresSafeArea()

            VStack {
                header
                Spacer()
                if case .failed(let message) = sweeper.state {
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 24)
                }
                controls
            }
        }
        .task {
            let room = existingRoomID.flatMap { store.room($0) }
            // A saved map is what lets positions line up with the register. A
            // room without one is swept as if for the first time.
            let map = existingRoomID.flatMap { store.worldMapData(for: $0) }
                .flatMap { Self.decodeWorldMap($0) }
            await sweeper.start(detector: scanner.detectorModel,
                                confidenceThreshold: scanner.confidenceThreshold,
                                known: room?.assets ?? [],
                                worldMap: map)
        }
        .onReceive(timer) { tick = $0 }
        // Everything downstream depends on this: what Vision is shown, and
        // where in the room a detection ends up pinned.
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.orientationDidChangeNotification)) { _ in
            sweeper.update(orientation: Self.currentOrientation())
        }
        .onAppear { sweeper.update(orientation: Self.currentOrientation()) }
        .statusBarHidden()
    }

    // MARK: - Overlays

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                counter("NEW", "\(sweeper.newCount)")
                counter("KNOWN", "\(sweeper.knownCount)")
                counter("FRAMES", "\(sweeper.framesAnalysed)")
                counter("SEEN", "\(sweeper.trackedCount)")
                counter("TIME", "\(Int(sweeper.elapsed))s")
                Spacer()
            }
            .padding(.horizontal, 18)

            Text(verbatim: hint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var hint: String {
        switch sweeper.state {
        case .preparing: "Starting the camera…"
        case .sweeping where sweeper.framesAnalysed < 4:
            "Walk the room slowly. Hold on anything with a label — a model number read off the case is worth more than a box around it."
        // A silent sweep is the failure that is hardest to diagnose, so say
        // which stage is quiet rather than showing a still viewfinder.
        case .sweeping where sweeper.framesAnalysed == 0 && sweeper.elapsed > 3:
            "No frames analysed yet. If this does not move, the camera feed is not reaching the detector."
        case .sweeping where sweeper.trackingLimited:
            "Hold steady and keep some of the room in view — the phone is still finding its bearings. Nothing is pinned until it has."
        case .sweeping where !sweeper.hasDetector:
            "No object-detection model loaded — only text and barcodes will be read."
        case .sweeping where sweeper.relocalization == .searching:
            RoomVideoSweeper.Relocalization.searching.label
        case .sweeping where sweeper.unplacedCount > 0:
            "\(sweeper.unplacedCount) found but not pinned (dashed) — move closer or step to the side so the camera can place them."
        case .sweeping where sweeper.knownCount > 0:
            "Teal boxes are already on this room's register and will not be onboarded again."
        case .sweeping:
            "Keep going. Pan slowly, and hold on anything with a label. A blue ↺ box is one you have come back to — it is counted once."
        default: sweeper.state.label
        }
    }

    private func counter(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(verbatim: value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                sweeper.reset()
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.18), in: Capsule())
                    .foregroundStyle(.white)
            }

            Button {
                finish()
            } label: {
                Label("Finish Sweep", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .disabled(sweeper.confirmedCount == 0)
            .opacity(sweeper.confirmedCount == 0 ? 0.5 : 1)
            .accessibilityHint("Saves the room map and onboards only what is new")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .padding(.top, 20)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    /// The interface orientation, taken from the scene rather than the device:
    /// a phone lying flat reports `.faceUp`, which says nothing about how the
    /// picture is drawn.
    private static func currentOrientation() -> SweepOrientation {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        switch scene?.effectiveGeometry.interfaceOrientation {
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    /// An ARWorldMap is archived with secure coding; anything else in that file
    /// is not a map and is ignored rather than trusted.
    private static func decodeWorldMap(_ data: Data) -> ARWorldMap? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    private func finish() {
        let elapsed = sweeper.elapsed
        let frames = sweeper.framesAnalysed
        let people = sweeper.peopleSeen
        let swept = sweeper.sweptAssets
        // Only what the room has not seen before is onboarded; the rest is
        // reported and its sighting refreshed.
        let onboarding = sweeper.newAssets
        sweeper.stop()

        Task {
            // Saved before the session is torn down: without a map the next
            // sweep of this room cannot relocalise, and everything in it would
            // be onboarded a second time.
            let map = await sweeper.currentWorldMap()

            var room = existingRoomID.flatMap { store.room($0) }
                ?? RoomRecord(name: roomName)
            if room.name.isEmpty { room.name = roomName }
            let result = RoomSpatialIndex.reconcile(room: room, sweep: swept)
            store.save(result.room)
            if let map,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: map,
                                                            requiringSecureCoding: true) {
                store.saveWorldMap(data, for: result.room.id)
            }

            scanner.recordSweep(assets: onboarding,
                                roomName: result.room.displayName,
                                duration: elapsed,
                                framesAnalysed: frames,
                                peopleSeen: people,
                                networkDevices: networkScanner.devices)
            sweeper.reset()
            onFinish()
            dismiss()
        }
    }
}

// MARK: - Preview layer

/// The live camera with detection boxes drawn over it.
///
/// The boxes are drawn in UIKit rather than SwiftUI because the preview crops
/// the frame to fill the screen, and `layerRectConverted(fromMetadataOutputRect:)`
/// is the only thing that knows exactly how much it cropped. Reimplementing that
/// mapping in SwiftUI would drift from the picture on any device whose camera
/// aspect ratio differs from the screen's.
private struct SweepPreview: UIViewRepresentable {
    let arView: ARView
    let boxes: [OverlayBox]
    let orientation: SweepOrientation

    func makeUIView(context: Context) -> SweepPreviewView {
        SweepPreviewView(arView: arView)
    }

    func updateUIView(_ view: SweepPreviewView, context: Context) {
        view.orientation = orientation
        view.apply(boxes: boxes)
    }
}

private final class SweepPreviewView: UIView {
    private let arView: ARView
    private var boxLayers: [UUID: CAShapeLayer] = [:]
    private var labelLayers: [UUID: CATextLayer] = [:]
    var orientation: SweepOrientation = .portrait {
        didSet { if orientation != oldValue { drawn = [] } }
    }

    init(arView: ARView) {
        self.arView = arView
        super.init(frame: .zero)
        arView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(arView)
        NSLayoutConstraint.activate([
            arView.topAnchor.constraint(equalTo: topAnchor),
            arView.bottomAnchor.constraint(equalTo: bottomAnchor),
            arView.leadingAnchor.constraint(equalTo: leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var drawn: [OverlayBox] = []

    func apply(boxes: [OverlayBox]) {
        // updateUIView fires on every parent re-render, including the clock
        // tick once a second. Redrawing an unchanged overlay would be pure
        // main-thread cost while Vision is already competing for the device.
        guard boxes != drawn else { return }
        drawn = boxes

        let live = Set(boxes.map(\.id))
        for (id, layer) in boxLayers where !live.contains(id) {
            layer.removeFromSuperlayer()
            boxLayers[id] = nil
            labelLayers[id]?.removeFromSuperlayer()
            labelLayers[id] = nil
        }

        // Boxes move every frame; animating them turns a live overlay into a
        // smear that lags the picture.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for entry in boxes {
            let rect = Self.viewRect(for: entry.box, in: bounds.size, orientation: orientation)
            guard rect.width > 1, rect.height > 1 else { continue }
            // Teal for something the room already has: it is being reported,
            // not onboarded, and that distinction is the whole feature. Blue
            // for something this sweep has just come back to and recognised —
            // the other half of it, within one sweep.
            let colour = (entry.isKnown ? UIColor.systemTeal
                          : entry.isReacquired ? UIColor.systemBlue
                          : entry.isRelevant ? UIColor.systemGreen : UIColor.lightGray).cgColor
            let label = (entry.isReacquired ? "\u{21BA} " : "") + entry.label
                + (entry.sightings > 1 ? " \u{00D7}\(entry.sightings)" : "")

            let shape = boxLayers[entry.id] ?? {
                let created = CAShapeLayer()
                created.fillColor = UIColor.clear.cgColor
                created.lineWidth = 2
                self.layer.addSublayer(created)
                boxLayers[entry.id] = created
                return created
            }()
            shape.strokeColor = colour
            // Dashed until it has a position: those are the boxes the camera
            // needs help with, and the ones a revisit cannot yet recognise by
            // place alone.
            shape.lineDashPattern = entry.isPinned ? nil : [6, 4]
            shape.path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath

            let text = labelLayers[entry.id] ?? {
                let created = CATextLayer()
                created.fontSize = 11
                created.alignmentMode = .center
                created.contentsScale = traitCollection.displayScale
                created.foregroundColor = UIColor.black.cgColor
                created.cornerRadius = 3
                created.masksToBounds = true
                self.layer.addSublayer(created)
                labelLayers[entry.id] = created
                return created
            }()
            text.string = label
            text.backgroundColor = colour
            let width = min(max(CGFloat(label.count) * 7 + 10, 34), rect.width + 40)
            text.frame = CGRect(x: rect.minX, y: max(rect.minY - 16, 0), width: width, height: 15)
        }
    }

    /// Maps a Vision box onto the aspect-filled camera image ARView draws.
    ///
    /// The camera frame is 4:3 and the screen is not, so the picture is cropped
    /// rather than letterboxed; drawing a box against the raw bounds would put
    /// it steadily further out towards the edges.
    static func viewRect(for box: CGRect,
                         in viewport: CGSize,
                         orientation: SweepOrientation = .portrait,
                         cameraAspect: CGFloat = 4.0 / 3.0) -> CGRect {
        // The camera frame is 4:3 landscape. Held upright it is shown 3:4, so
        // which way round the aspect goes depends on how the phone is held.
        let imageSize = orientation.isPortrait
            ? CGSize(width: viewport.height / cameraAspect, height: viewport.height)
            : CGSize(width: viewport.width, height: viewport.width / cameraAspect)
        let scale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let offset = CGPoint(x: (viewport.width - drawn.width) / 2,
                             y: (viewport.height - drawn.height) / 2)
        // Vision's origin is bottom-left; UIKit's is top-left.
        return CGRect(x: offset.x + box.minX * drawn.width,
                      y: offset.y + (1 - box.maxY) * drawn.height,
                      width: box.width * drawn.width,
                      height: box.height * drawn.height)
    }
}
