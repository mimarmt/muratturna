import Foundation
import SwiftUI
import UIKit
import Vision

/// Stores note photos on device and reads the text in them (Vision OCR, on device).
enum PhotoStore {
    static var directory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Saves a downscaled JPEG and returns its file name.
    static func save(_ image: UIImage) -> String? {
        let name = "photo-\(UUID().uuidString).jpg"
        guard let data = resized(image, maxSide: 2048).jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    nonisolated(unsafe) private static let thumbs = NSCache<NSString, UIImage>()

    /// Small cached version for list rows.
    static func thumbnail(_ name: String) -> UIImage? {
        if let t = thumbs.object(forKey: name as NSString) { return t }
        guard let img = image(name) else { return nil }
        let t = resized(img, maxSide: 160)
        thumbs.setObject(t, forKey: name as NSString)
        return t
    }

    static func image(_ name: String) -> UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent(name).path)
    }

    static func delete(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// iOS moves notification attachments into its own store, so each one gets a small copy.
    static func attachmentCopy(_ name: String) -> URL? {
        guard let img = image(name),
              let data = resized(img, maxSide: 600).jpegData(compressionQuality: 0.7) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString).jpg")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Recognizes Turkish, English and German text in the photo.
    nonisolated static func recognizeText(in image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["tr-TR", "en-US", "de-DE"]
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation)
            try? handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// System camera for taking a photo.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
