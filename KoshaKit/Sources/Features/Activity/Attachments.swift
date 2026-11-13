import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import Model
import API
import Store
import Design

/// Up to 10 MB each, as the server takes them.
private let limit = 10 * 1024 * 1024

/// Decoded thumbnails by attachment id. A file never changes under its id, so one decode per run is enough.
/// ponytail: memory only, and each thumbnail downloads the whole file; a server preview would replace both.
@MainActor private var thumbs: [String: Image] = [:]

/// Attachments: each file with its size, opened in Quick Look on tap, removed after a check; Attach another. Ported from
/// Attachments.kt.
struct AttachmentsCard: View {
    let t: Model.Transaction
    let onAttach: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var files: [Attachment] = []
    @State private var removing: Attachment?
    @State private var preview: URL?

    var body: some View {
        let c = theme.colors
        Group {
            if !files.isEmpty || kosha.canWrite {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L.tx_attachments()).kFont(.small).foregroundStyle(c.ink3)
                            Spacer()
                            if kosha.canWrite {
                                Button(action: onAttach) {
                                    HStack(spacing: 4) {
                                        PhIcon("paperclip", size: 16)
                                        Text(files.isEmpty ? L.tx_attach_receipt() : L.tx_attach_another()).kFont(.small)
                                            .foregroundStyle(c.ink2)
                                    }
                                    .frame(minHeight: 44)
                                }
                                .buttonStyle(PressStyle())
                            }
                        }
                        ForEach(files) { a in row(a) }
                    }
                }
            }
        }
        .task(id: "\(t.id)/\(kosha.version)") {
            await kosha.load("attachments/\(t.id)", into: { (l: Loaded<[Attachment]>) in files = l.value ?? [] }) { api in
                try await api.get("/api/app/transactions/\(t.id)/attachments")
            }
        }
        .quickLookPreview($preview)
        .kSheet(item: $removing) { a in
            VStack(spacing: 10) {
                SheetHeader(L.tx_remove_file_title(name: a.name)) { removing = nil }
                Text(L.tx_remove_file_body()).kFont(.small).foregroundStyle(c.ink2).frame(maxWidth: .infinity, alignment: .leading)
                KButton(L.common_remove(), style: .danger) {
                    removing = nil
                    Task {
                        let done: Void? = await kosha.write(toasts) { try await kosha.api.send("DELETE", "/api/app/attachments/\(a.id)") }
                        if done != nil { toasts.show(L.tx_removed()) }
                    }
                }
                KButton(L.common_cancel(), style: .secondary) { removing = nil }
            }
        }
    }

    private func row(_ a: Attachment) -> some View {
        let c = theme.colors
        return HStack(spacing: 10) {
            Button { Task { await open(a) } } label: {
                HStack(spacing: 10) {
                    Thumb(a: a)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).lineLimit(1)
                        Text(fileSize(a.size)).kFont(.figure(12, .regular)).foregroundStyle(c.ink3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            if kosha.canWrite {
                IconButton("trash", label: L.tx_remove_file(name: a.name)) { removing = a }
            }
        }
    }

    /// Saves the file where Quick Look can read it, then shows it.
    private func open(_ a: Attachment) async {
        do {
            let data = try await kosha.api.bytes("/api/app/attachments/\(a.id)")
            let safe = a.name.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(a.id)-\(String(safe))")
            try data.write(to: url, options: .atomic)
            preview = url
        } catch let e as KoshaError {
            if case .api(_, let err) = e { toasts.show(err.message, warning: true) } else {
                toasts.show(L.tx_fetch_failed(name: a.name), warning: true)
            }
        } catch {
            toasts.show(L.tx_fetch_failed(name: a.name), warning: true)
        }
    }
}

/// An image attachment as a small picture; a PDF, or one that won't load, as its icon.
private struct Thumb: View {
    let a: Attachment
    @Environment(Kosha.self) private var kosha
    @Environment(\.kosha) private var theme
    @State private var image: Image?

    var body: some View {
        let c = theme.colors
        ZStack {
            if let image {
                image.resizable().scaledToFill()
            } else {
                PhIcon(a.type == "application/pdf" ? "file-pdf" : "file-image", size: 22, color: c.ink3)
            }
        }
        .frame(width: 56, height: 72)
        .background(c.soft)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(c.line))
        .accessibilityHidden(true)
        .task(id: a.id) {
            if let cached = thumbs[a.id] { image = cached; return }
            guard a.type.hasPrefix("image/"), let data = try? await kosha.api.bytes("/api/app/attachments/\(a.id)"),
                  let img = platformImage(data) else { return }
            thumbs[a.id] = img
            image = img
        }
    }
}

/// Attach receipt or document: take a photo, choose from photos, or choose a file (PDF or image). "Up to 10 MB each."
/// A row shows the file while it uploads.
struct AttachSheet: View {
    let transactionId: String
    let close: () -> Void
    @Environment(Kosha.self) private var kosha
    @Environment(Toasts.self) private var toasts
    @Environment(\.kosha) private var theme
    @State private var uploading: (name: String, size: Int)?
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var camera = false

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(L.tx_attach_receipt(), onClose: close)
            Card(tight: true) {
                #if os(iOS)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    choice("camera", L.app_act_take_photo()) { camera = true }
                    Hairline()
                }
                #endif
                PhotosPicker(selection: $photo, matching: .images) {
                    ChoiceLabel(icon: "images", title: L.app_act_choose_photos(), sub: nil)
                }
                .buttonStyle(PressStyle())
                Hairline()
                choice("file-pdf", L.server_choose_file(), L.app_act_file_hint()) { importing = true }
            }
            Text(L.app_act_up_to()).kFont(.xs).foregroundStyle(c.ink3).padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 4)
            if let u = uploading {
                HStack(spacing: 10) {
                    Text(u.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(fileSize(Int64(u.size))).kFont(.figure(13, .regular)).foregroundStyle(c.ink3)
                    ProgressView().controlSize(.small).tint(c.brand)
                    Text(L.tx_attaching()).kFont(.xs).foregroundStyle(c.ink2)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(c.line))
                .padding(.top, 8)
            }
        }
        .disabled(uploading != nil)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                let type = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await upload(name: "photo.\(type.preferredFilenameExtension ?? "jpg")",
                             type: type.preferredMIMEType ?? "image/jpeg", data: data)
                photo = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                return toasts.show(L.tx_fetch_failed(name: url.lastPathComponent), warning: true)
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            Task { await upload(name: url.lastPathComponent, type: type, data: data) }
        }
        #if os(iOS)
        .fullScreen(isPresented: $camera) {
            CameraPicker { data in
                camera = false
                if let data { Task { await upload(name: "photo.jpg", type: "image/jpeg", data: data) } }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private func upload(name: String, type: String, data: Data) async {
        if data.count > limit { return toasts.show(L.tx_file_too_big(files: name), warning: true) }
        uploading = (name, data.count)
        let done = await kosha.write(toasts) {
            try await kosha.api.upload("/api/app/transactions/\(transactionId)/attachments", name: name, type: type, data: data)
        }
        uploading = nil
        if done != nil {
            toasts.show(L.tx_attached(count: 1))
            close()
        }
    }

    private func choice(_ icon: String, _ title: String, _ sub: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { ChoiceLabel(icon: icon, title: title, sub: sub) }.buttonStyle(PressStyle())
    }
}

/// One way to attach: an icon tile, a title and an optional line under it.
private struct ChoiceLabel: View {
    let icon: String
    let title: String
    let sub: String?
    @Environment(\.kosha) private var theme

    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).kFont(.head)
                if let sub { Text(sub).kFont(.small).foregroundStyle(theme.colors.ink3) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: theme.dims.row)
        .contentShape(Rectangle())
    }
}

#if os(iOS)
/// The system camera for one photo, handed back as JPEG (nil when cancelled).
struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (Data?) -> Void
        init(onDone: @escaping (Data?) -> Void) { self.onDone = onDone }

        func imagePickerController(
            _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onDone((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.85))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}
#endif
