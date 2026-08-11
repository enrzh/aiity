import AVFoundation
import SwiftUI
import UIKit

struct QRCodeScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, ScannerViewControllerDelegate {
        let parent: QRCodeScannerView
        init(parent: QRCodeScannerView) { self.parent = parent }
        func scanner(_ scanner: ScannerViewController, found code: String) { parent.onCode(code) }
        func scanner(_ scanner: ScannerViewController, failed message: String) { parent.onError(message) }
    }
}

protocol ScannerViewControllerDelegate: AnyObject {
    func scanner(_ scanner: ScannerViewController, found code: String)
    func scanner(_ scanner: ScannerViewController, failed message: String)
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: ScannerViewControllerDelegate?
    private let session = AVCaptureSession()
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCamera()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    private func configureCamera() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            delegate?.scanner(self, failed: String(localized: "Kamera ist nicht verfügbar."))
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            delegate?.scanner(self, failed: String(localized: "QR-Scanner konnte nicht gestartet werden."))
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        Task.detached { [session] in session.startRunning() }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !delivered,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue else { return }
        delivered = true
        session.stopRunning()
        delegate?.scanner(self, found: code)
    }
}
