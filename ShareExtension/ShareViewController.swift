import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Entry point for the share sheet. Pulls the shared text out of the extension
/// context and hands it to SwiftUI.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            let text = await extractSharedText()
            install(text: text)
        }
    }

    // MARK: - Input

    private func extractSharedText() async -> String {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return "" }

        for item in items {
            for provider in item.attachments ?? [] {
                for type in [UTType.plainText, UTType.text, UTType.utf8PlainText] {
                    guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }
                    if let loaded = try? await provider.loadItem(forTypeIdentifier: type.identifier) {
                        if let string = loaded as? String, !string.isEmpty {
                            return string
                        }
                        if let data = loaded as? Data, let string = String(data: data, encoding: .utf8), !string.isEmpty {
                            return string
                        }
                        if let url = loaded as? URL {
                            return url.absoluteString
                        }
                    }
                }
            }
            // Messages sometimes supplies the body here rather than as an attachment.
            if let attributed = item.attributedContentText?.string, !attributed.isEmpty {
                return attributed
            }
        }
        return ""
    }

    // MARK: - UI

    private func install(text: String) {
        let root = ShareRootView(
            sharedText: text,
            openHost: { [weak self] url, completion in
                // NSExtensionContext.open is the only sanctioned way for an
                // extension to launch its containing app; UIApplication.shared
                // is unavailable here.
                guard let context = self?.extensionContext else {
                    completion(false)
                    return
                }
                context.open(url, completionHandler: completion)
            },
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }
        )

        let hosting: UIHostingController<AnyView>
        switch SharedStore.shared {
        case .success(let container):
            hosting = UIHostingController(rootView: AnyView(root.modelContainer(container)))
        case .failure(let error):
            hosting = UIHostingController(rootView: AnyView(
                ShareErrorView(message: error.localizedDescription) { [weak self] in self?.cancel() }
            ))
        }

        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosting.didMove(toParent: self)
    }

    // MARK: - Completion

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "com.explog.share", code: 0))
    }
}

private struct ShareErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("ExpLog isn't set up", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                }
            }
        }
    }
}
