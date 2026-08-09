import UIKit
import WebKit

/// Hosts a popup web view opened by a browser-tier mini-app (`window.open`,
/// `target="_blank"`, an OAuth SDK's sign-in window).
///
/// The child web view is created by `MiniAppRunnerView.Coordinator` from the
/// configuration WebKit hands it — required, and also what keeps
/// `window.opener`/`postMessage` alive, which is the whole point of a popup in
/// an OAuth flow. This controller only gives it a place to live and a way out.
final class BrowserPopupViewController: UIViewController {

    let webView: WKWebView
    /// Called when the user closes the popup (not when the page closes itself).
    var onClose: (() -> Void)?

    private let titleLabel = UILabel()
    private var urlObservation: NSKeyValueObservation?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .secondaryLabel
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.textAlignment = .center
        titleLabel.text = webView.url?.host

        let closeButton = UIButton(type: .system)
        closeButton.setTitle(String(localized: "Fertig"), for: .normal)
        closeButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        closeButton.accessibilityIdentifier = "miniapp-popup-close"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let bar = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        bar.axis = .horizontal
        bar.spacing = 12
        bar.alignment = .center
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        let separator = UIView()
        separator.backgroundColor = .separator

        for subview in [bar, separator, webView] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // The host is the only trustworthy identity a popup has; the page title
        // is attacker-controlled text and would read like app chrome here.
        urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
            self?.titleLabel.text = webView.url?.host
        }
    }

    @objc private func closeTapped() {
        onClose?()
        dismiss(animated: true)
    }
}
