import SwiftUI
import UIKit

enum CameraAttachmentStore {
    static func saveJPEG(_ data: Data) -> ChatAttachment? {
        guard let mediaId = MediaStore.save(data: data, filename: "camera.jpg", mimeType: "image/jpeg") else {
            return nil
        }
        return ChatAttachment(
            mediaId: mediaId,
            filename: "camera-\(mediaId.prefix(8)).jpg",
            mimeType: "image/jpeg",
            kind: .image
        )
    }
}

struct CameraImagePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onCapture: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraImagePicker

        init(parent: CameraImagePicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.88) {
                parent.onCapture(data)
            }
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}
