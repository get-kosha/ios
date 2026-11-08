import SwiftUI
import PhotosUI
import Model
import Design
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// Receipts go to the AI at most this size on the long side (ai.tsx shrink).
private let longSide: CGFloat = 1600

/// Scan a receipt (ReceiptCamera): a full-screen camera with a receipt frame, the shutter, flash and Choose a photo.
/// The photo is shrunk to 1600px, read by AI into the form and attached once the entry is saved. Without camera
/// permission it explains and still offers a photo. Dark whatever the theme, in the person's accent.
struct ReceiptCamera: View {
    let model: AddModel
    @Environment(\.kosha) private var theme
    @State private var photo: PhotosPickerItem?
    @State private var picking = false
    #if os(iOS)
    @State private var camera = CameraController()
    #endif

    var body: some View {
        let c = KColors.of(dark: true, accent: Accent(rawValue: model.meta?.pref("accent", "teal") ?? "teal") ?? .teal,
                           neutral: theme.colors.neutral)
        ZStack {
            c.bg.ignoresSafeArea()
            #if os(iOS)
            if camera.granted == true { CameraPreview(session: camera.session).ignoresSafeArea() }
            #endif
            VStack(spacing: 0) {
                HStack {
                    IconButton("x", label: L.common_close(), color: c.ink) { model.camera = false }
                    Spacer()
                    Text(L.add_scan_receipt()).kFont(.sans(16, .medium)).foregroundStyle(c.ink)
                    Spacer()
                    #if os(iOS)
                    if camera.granted == true {
                        IconButton(camera.flash ? "lightning" : "lightning-slash",
                                   label: camera.flash ? L.app_add_flash_on() : L.app_add_flash_off(), color: c.ink) {
                            camera.flash.toggle()
                        }
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                    #else
                    Color.clear.frame(width: 44, height: 44)
                    #endif
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 56)
                ZStack {
                    if granted {
                        Frame(color: c.ink).padding(.horizontal, 52).padding(.vertical, 24)
                    } else {
                        VStack(spacing: 16) {
                            PhIcon("camera-slash", size: 32, color: c.ink2)
                            Text(L.app_add_camera_needed()).foregroundStyle(c.ink2).multilineTextAlignment(.center)
                            #if os(iOS)
                            KButton(L.app_add_allow_camera(), style: .soft, size: .medium) { camera.allow() }
                                .fixedSize()
                            #endif
                        }
                        .padding(32)
                    }
                    if model.reading == .receipt {
                        HStack(spacing: 10) {
                            ProgressView().tint(c.brand)
                            Text(L.add_hint_reading_receipt()).foregroundStyle(c.ink)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(c.soft, in: .capsule)
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxHeight: .infinity)
                if granted {
                    Text(L.app_add_camera_hint()).foregroundStyle(c.ink2).padding(.bottom, 24)
                }
                HStack {
                    Button { picking = true } label: { galleryButton(c) }
                        .buttonStyle(PressStyle())
                        .accessibilityLabel(L.app_add_choose_photo())
                    Spacer()
                    #if os(iOS)
                    if camera.granted == true {
                        Button {
                            camera.capture { data in send(data) }
                        } label: {
                            Circle().fill(c.ink).frame(width: 64, height: 64)
                                .padding(5)
                                .overlay(Circle().strokeBorder(c.ink, lineWidth: 3))
                        }
                        .buttonStyle(PressStyle())
                        .disabled(model.reading != nil)
                        .accessibilityLabel(L.app_add_take_photo())
                    }
                    #endif
                    Spacer()
                    Color.clear.frame(width: 52, height: 52)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            }
        }
        .environment(\.colorScheme, .dark)
        .photosPicker(isPresented: $picking, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                photo = nil
                send(data.flatMap(shrink))
            }
        }
        #if os(iOS)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        #endif
    }

    private func galleryButton(_ c: KColors) -> some View {
        PhIcon("images", size: 26, color: c.ink)
            .frame(width: 52, height: 52)
            .background(c.soft, in: .rect(cornerRadius: 14))
    }

    private var granted: Bool {
        #if os(iOS)
        camera.granted == true
        #else
        false
        #endif
    }

    private func send(_ jpeg: Data?) {
        guard let jpeg else { return model.toasts.show(L.add_error_receipt(), warning: true) }
        model.scan(jpeg)
    }
}

/// The receipt frame: four corners in the ground's ink.
private struct Frame: View {
    let color: Color

    var body: some View {
        GeometryReader { p in
            let w = p.size.width, h = p.size.height, l: CGFloat = 28
            Path { path in
                path.move(to: CGPoint(x: 0, y: l)); path.addLine(to: .zero); path.addLine(to: CGPoint(x: l, y: 0))
                path.move(to: CGPoint(x: w - l, y: 0)); path.addLine(to: CGPoint(x: w, y: 0)); path.addLine(to: CGPoint(x: w, y: l))
                path.move(to: CGPoint(x: w, y: h - l)); path.addLine(to: CGPoint(x: w, y: h)); path.addLine(to: CGPoint(x: w - l, y: h))
                path.move(to: CGPoint(x: l, y: h)); path.addLine(to: CGPoint(x: 0, y: h)); path.addLine(to: CGPoint(x: 0, y: h - l))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// A photo as a JPEG at most 1600px on its long side.
func shrink(_ data: Data) -> Data? {
    #if os(iOS)
    guard let image = UIImage(data: data) else { return nil }
    let scale = min(1, longSide / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        .jpegData(compressionQuality: 0.85)
    #else
    return data
    #endif
}

#if os(iOS)
/// The back camera's session and photo output, for the receipt camera.
@MainActor @Observable
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate {
    @ObservationIgnored nonisolated(unsafe) let session = AVCaptureSession()
    @ObservationIgnored private let output = AVCapturePhotoOutput()
    @ObservationIgnored private var done: ((Data?) -> Void)?
    private(set) var granted: Bool?
    var flash = false

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted == true, session.inputs.isEmpty,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        let s = session
        Task.detached { s.startRunning() }
    }

    func stop() {
        let s = session
        Task.detached { s.stopRunning() }
    }

    /// Asked and refused: only Settings can turn it on now.
    func allow() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            Task { await start() }
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func capture(_ done: @escaping (Data?) -> Void) {
        self.done = done
        let settings = AVCapturePhotoSettings()
        if output.supportedFlashModes.contains(.on) { settings.flashMode = flash ? .on : .off }
        output.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation().flatMap(shrink)
        Task { @MainActor in
            done?(data)
            done = nil
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
#endif
