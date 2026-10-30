import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import TodoCore
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Upload/preview state for one task. The attachment list itself stays owned by the caller.
@MainActor @Observable
final class AttachmentsModel {
    var uploading = false
    var errorKey: String?
    var previewURL: URL?
    var openingID: UUID?

    private static let previewDirectory = FileManager.default.temporaryDirectory.appending(path: "attachment-preview", directoryHint: .isDirectory)

    func upload(
        data: Data, filename: String, taskID: UUID, list: Binding<[TaskAttachment]>, _ app: AppModel
    ) async {
        guard let client = app.client else { return }
        uploading = true; errorKey = nil
        defer { uploading = false }
        do {
            let prepared = try Self.prepare(data: data, filename: filename)
            let created = try await client.uploadAttachment(
                taskID: taskID, filename: prepared.filename, mediaType: prepared.mediaType, data: prepared.data)
            if !list.wrappedValue.contains(where: { $0.id == created.id }) { list.wrappedValue.append(created) }
        } catch { await fail(error, app) }
    }

    func open(_ attachment: TaskAttachment, _ app: AppModel) async {
        guard let client = app.client else { return }
        openingID = attachment.id; errorKey = nil
        defer { openingID = nil }
        do { previewURL = try await client.downloadAttachmentFile(attachment, into: Self.previewDirectory) }
        catch { await fail(error, app) }
    }

    func clearPreviewFiles() { try? FileManager.default.removeItem(at: Self.previewDirectory) }

    private func fail(_ error: Error, _ app: AppModel) async {
        switch error as? APIError {
        case .unauthorized: await app.handle(error)
        case .invalidInput, .server(status: 413, _), .server(status: 415, _): errorKey = "attachment.error.invalid"
        case .notFound, .forbidden: errorKey = "attachment.error.notFound"
        case .some(let e) where e == .decoding("attachment checksum mismatch"): errorKey = "attachment.error.corrupt"
        default:
            errorKey = (error as? AttachmentPreparationError) == .unsupported ? "attachment.error.unsupported"
                : (error as? AttachmentPreparationError) == .tooLarge ? "attachment.error.tooLarge" : "attachment.error.failed"
        }
    }

    enum AttachmentPreparationError: Error { case unsupported, tooLarge }

    /// Accepts PNG/JPEG/WebP/PDF as-is; other images (HEIC from the photo library) are converted to JPEG.
    static func prepare(data: Data, filename: String) throws -> (data: Data, filename: String, mediaType: String) {
        if let type = AttachmentRules.sniffMediaType(data) {
            guard data.count <= AttachmentRules.maxSize else {
                if type.hasPrefix("image/"), let jpeg = jpegData(from: data) { return (jpeg, jpegName(filename), "image/jpeg") }
                throw AttachmentPreparationError.tooLarge
            }
            return (data, filename, type)
        }
        guard let jpeg = jpegData(from: data) else { throw AttachmentPreparationError.unsupported }
        guard jpeg.count <= AttachmentRules.maxSize else { throw AttachmentPreparationError.tooLarge }
        return (jpeg, jpegName(filename), "image/jpeg")
    }

    private static func jpegName(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension + ".jpg"
    }

    private static func jpegData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

struct AttachmentsSection: View {
    @Environment(AppModel.self) private var app
    let taskID: UUID
    @Binding var attachments: [TaskAttachment]
    @State private var model = AttachmentsModel()
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("task.attachments").font(.sectionTitle)
            ForEach(attachments) { a in
                Button { Task { await model.open(a, app) } } label: {
                    HStack {
                        AttachmentThumbnail(attachment: a)
                        VStack(alignment: .leading) {
                            Text(verbatim: a.filename).lineLimit(1)
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.openingID == a.id { ProgressView() }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("attachment.open"))
            }
            HStack {
                PhotosPicker(selection: $pickedPhoto, matching: .images) { Label("attachment.addPhoto", systemImage: "photo.badge.plus") }
                Spacer()
                Button { importing = true } label: { Label("attachment.addFile", systemImage: "paperclip") }.buttonStyle(.plain)
                if model.uploading { ProgressView() }
            }
            .disabled(model.uploading)
            if let key = model.errorKey {
                Text(LocalizedStringKey(key)).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.subheadline)
        .padding(Space.m)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { model.errorKey = "attachment.error.failed"; return }
                await model.upload(data: data, filename: "Foto.jpg", taskID: taskID, list: $attachments, app)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg, .webP, .pdf]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { model.errorKey = "attachment.error.failed"; return }
                await model.upload(data: data, filename: url.lastPathComponent, taskID: taskID, list: $attachments, app)
            }
        }
        .quickLookPreview($model.previewURL)
        .onDisappear { model.clearPreviewFiles() }
    }
}

/// Image attachments load their original through the authenticated preview route (AsyncImage cannot send the Bearer token).
private struct AttachmentThumbnail: View {
    @Environment(AppModel.self) private var app
    let attachment: TaskAttachment
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: attachment.isImage ? "photo" : "doc.richtext").foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .accessibilityHidden(true)
        .task(id: attachment.id) {
            guard attachment.isImage, let client = app.client,
                let data = try? await client.previewAttachment(attachment.id)
            else { return }
            image = Self.image(from: data)
        }
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        UIImage(data: data).map { Image(uiImage: $0) }
        #else
        NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }
}
