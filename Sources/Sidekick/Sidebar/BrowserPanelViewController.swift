import Cocoa
import WebKit

class BrowserPanelViewController: NSViewController {
    // UI Elements
    private var navigationView: NSView!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var urlField: NSTextField!
    private var externalButton: NSButton!
    private var webView: WKWebView!

    // State
    private var currentURL: URL?

    /// The page currently shown, for session persistence.
    var pageURL: URL? {
        webView?.url ?? currentURL
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(hex: "#181825")?.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupWebView()
        setupNavigationBar()
        layoutViews()
        loadDefaultPage()
    }

    private func setupWebView() {
        // Configure WebView with JavaScript enabled and full feature set
        let configuration = WKWebViewConfiguration()
        let preferences = WKPreferences()

        // For macOS 11.0+, JavaScript is enabled by default per navigation
        if #available(macOS 11.0, *) {
            // JavaScript is enabled by default, but we can set it per navigation if needed
        } else {
            preferences.javaScriptEnabled = true
        }

        preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences = preferences
        configuration.websiteDataStore = .default()
        configuration.userContentController = makeUserContentController()

        // Enable developer extras for debugging (optional)
        if #available(macOS 13.3, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        // Allow back/forward gestures
        webView.allowsBackForwardNavigationGestures = true

        // Keep page drawing opaque so sites render like they do in Safari/Chrome.
        webView.setValue(true, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .white
        }

        view.addSubview(webView)
    }

    private func makeUserContentController() -> WKUserContentController {
        let controller = WKUserContentController()
        let source = """
        (() => {
            const localHosts = new Set(['localhost', '127.0.0.1', '::1']);
            if (!localHosts.has(window.location.hostname)) {
                return;
            }

            const style = document.createElement('style');
            style.textContent = `
                vite-error-overlay,
                nextjs-portal,
                astro-error-overlay,
                astro-dev-toolbar,
                iframe#webpack-dev-server-client-overlay,
                div#webpack-dev-server-client-overlay,
                iframe[data-react-error-overlay],
                div[data-react-error-overlay],
                iframe[title="webpack-dev-server-client-overlay"],
                iframe[style*="2147483647"],
                [data-nextjs-dialog-overlay],
                [data-nextjs-toast],
                [data-nextjs-dev-overlay],
                [data-react-error-overlay] {
                    display: none !important;
                    visibility: hidden !important;
                    pointer-events: none !important;
                }
            `;

            const overlayText = [
                'Uncaught runtime errors:',
                'Unexpected token',
                'Failed to compile',
                'Compiled with problems'
            ];

            const looksLikeDevOverlay = (element) => {
                if (!(element instanceof HTMLElement)) {
                    return false;
                }

                const id = element.id || '';
                const className = typeof element.className === 'string' ? element.className : '';
                const role = element.getAttribute('role') || '';
                const text = element.innerText || element.textContent || '';
                const style = window.getComputedStyle(element);
                const zIndex = Number.parseInt(style.zIndex, 10);

                if (id.includes('webpack-dev-server-client-overlay')) { return true; }
                if (className.includes('react-error-overlay')) { return true; }
                if (element.tagName.toLowerCase() === 'vite-error-overlay') { return true; }
                if (role === 'dialog' && overlayText.some((value) => text.includes(value))) { return true; }

                const isFullScreenFixed =
                    style.position === 'fixed' &&
                    element.offsetWidth >= window.innerWidth * 0.8 &&
                    element.offsetHeight >= window.innerHeight * 0.4 &&
                    Number.isFinite(zIndex) &&
                    zIndex >= 10000;

                return isFullScreenFixed && overlayText.some((value) => text.includes(value));
            };

            const removeDevOverlays = () => {
                document.querySelectorAll('body *').forEach((element) => {
                    if (looksLikeDevOverlay(element)) {
                        element.remove();
                    }
                });
            };

            const installStyle = () => {
                const target = document.head || document.documentElement;
                if (target && !style.isConnected) {
                    target.appendChild(style);
                }
                removeDevOverlays();
            };

            installStyle();
            document.addEventListener('DOMContentLoaded', installStyle, { once: true });
            new MutationObserver(removeDevOverlays).observe(document.documentElement, {
                childList: true,
                subtree: true
            });
        })();
        """
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(script)
        return controller
    }

    private func setupNavigationBar() {
        navigationView = NSView()
        navigationView.wantsLayer = true
        navigationView.layer?.backgroundColor = NSColor(hex: "#11111b")?.cgColor
        navigationView.translatesAutoresizingMaskIntoConstraints = false

        // Back button
        backButton = NSButton()
        backButton.title = "←"
        backButton.bezelStyle = .texturedRounded
        backButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        backButton.target = self
        backButton.action = #selector(backButtonClicked)
        backButton.toolTip = "Go back"
        backButton.isEnabled = false
        backButton.translatesAutoresizingMaskIntoConstraints = false

        // Forward button
        forwardButton = NSButton()
        forwardButton.title = "→"
        forwardButton.bezelStyle = .texturedRounded
        forwardButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        forwardButton.target = self
        forwardButton.action = #selector(forwardButtonClicked)
        forwardButton.toolTip = "Go forward"
        forwardButton.isEnabled = false
        forwardButton.translatesAutoresizingMaskIntoConstraints = false

        // Reload button
        reloadButton = NSButton()
        reloadButton.title = "⟳"
        reloadButton.bezelStyle = .texturedRounded
        reloadButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        reloadButton.target = self
        reloadButton.action = #selector(reloadButtonClicked)
        reloadButton.toolTip = "Reload page"
        reloadButton.translatesAutoresizingMaskIntoConstraints = false

        // URL field
        urlField = NSTextField()
        urlField.placeholderString = "Search or enter URL..."
        urlField.font = NSFont.systemFont(ofSize: 13)
        urlField.target = self
        urlField.action = #selector(urlFieldEnterPressed)
        urlField.translatesAutoresizingMaskIntoConstraints = false

        // External browser button
        externalButton = NSButton()
        externalButton.title = "⧉"
        externalButton.bezelStyle = .texturedRounded
        externalButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        externalButton.target = self
        externalButton.action = #selector(openInSystemBrowser)
        externalButton.toolTip = "Open in system browser"
        externalButton.translatesAutoresizingMaskIntoConstraints = false

        navigationView.addSubview(backButton)
        navigationView.addSubview(forwardButton)
        navigationView.addSubview(reloadButton)
        navigationView.addSubview(urlField)
        navigationView.addSubview(externalButton)

        view.addSubview(navigationView)
    }

    private func layoutViews() {
        NSLayoutConstraint.activate([
            // Navigation view
            navigationView.topAnchor.constraint(equalTo: view.topAnchor),
            navigationView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigationView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navigationView.heightAnchor.constraint(equalToConstant: 40),

            // Back button
            backButton.leadingAnchor.constraint(equalTo: navigationView.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: navigationView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 32),
            backButton.heightAnchor.constraint(equalToConstant: 24),

            // Forward button
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            forwardButton.centerYAnchor.constraint(equalTo: navigationView.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 32),
            forwardButton.heightAnchor.constraint(equalToConstant: 24),

            // Reload button
            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4),
            reloadButton.centerYAnchor.constraint(equalTo: navigationView.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 32),
            reloadButton.heightAnchor.constraint(equalToConstant: 24),

            // External button
            externalButton.trailingAnchor.constraint(equalTo: navigationView.trailingAnchor, constant: -8),
            externalButton.centerYAnchor.constraint(equalTo: navigationView.centerYAnchor),
            externalButton.widthAnchor.constraint(equalToConstant: 32),
            externalButton.heightAnchor.constraint(equalToConstant: 24),

            // URL field
            urlField.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 8),
            urlField.trailingAnchor.constraint(equalTo: externalButton.leadingAnchor, constant: -8),
            urlField.centerYAnchor.constraint(equalTo: navigationView.centerYAnchor),
            urlField.heightAnchor.constraint(equalToConstant: 22),

            // Web view
            webView.topAnchor.constraint(equalTo: navigationView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadDefaultPage() {
        let htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Sidekick Browser</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
                    background: #1e1e2e;
                    color: #cdd6f4;
                    margin: 0;
                    padding: 40px;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    min-height: 100vh;
                    text-align: center;
                }
                .container {
                    max-width: 600px;
                }
                h1 {
                    color: #89b4fa;
                    font-size: 2.5em;
                    margin-bottom: 0.5em;
                    font-weight: 300;
                }
                p {
                    font-size: 1.1em;
                    line-height: 1.6;
                    color: #a6adc8;
                    margin-bottom: 1.5em;
                }
                .quick-links {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
                    gap: 20px;
                    margin-top: 30px;
                }
                .quick-link {
                    background: #313244;
                    border-radius: 8px;
                    padding: 20px;
                    text-decoration: none;
                    color: #cdd6f4;
                    border: 1px solid #45475a;
                    transition: all 0.2s ease;
                }
                .quick-link:hover {
                    background: #45475a;
                    border-color: #89b4fa;
                    transform: translateY(-2px);
                }
                .quick-link h3 {
                    margin: 0 0 8px 0;
                    color: #89b4fa;
                    font-size: 1.1em;
                }
                .quick-link p {
                    margin: 0;
                    font-size: 0.9em;
                    color: #a6adc8;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>🌐 Sidekick Browser</h1>
                <p>Browse the web without leaving your terminal workspace. Type a URL or search term in the address bar above to get started.</p>

                <div class="quick-links">
                    <a href="https://github.com" class="quick-link">
                        <h3>GitHub</h3>
                        <p>Code repositories and collaboration</p>
                    </a>
                    <a href="https://stackoverflow.com" class="quick-link">
                        <h3>Stack Overflow</h3>
                        <p>Programming Q&A community</p>
                    </a>
                    <a href="https://developer.mozilla.org" class="quick-link">
                        <h3>MDN Docs</h3>
                        <p>Web development documentation</p>
                    </a>
                    <a href="https://docs.swift.org" class="quick-link">
                        <h3>Swift Docs</h3>
                        <p>Swift programming language docs</p>
                    </a>
                </div>
            </div>
        </body>
        </html>
        """

        webView.loadHTMLString(htmlContent, baseURL: nil)
        urlField.stringValue = ""
    }

    // MARK: - Button Actions

    @objc private func backButtonClicked() {
        webView.goBack()
    }

    @objc private func forwardButtonClicked() {
        webView.goForward()
    }

    @objc private func reloadButtonClicked() {
        webView.reloadFromOrigin()
    }

    @objc private func openInSystemBrowser() {
        if let url = currentURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func urlFieldEnterPressed() {
        let input = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        let url = processURLInput(input)
        loadURL(url)
    }

    /// Navigates the pane to a URL programmatically (e.g. detected dev server).
    func navigate(to url: URL) {
        _ = view
        urlField.stringValue = url.absoluteString
        loadURL(url)
    }

    private func loadURL(_ url: URL) {
        let request = cacheBypassingRequest(for: url)

        guard isLocalDevelopmentURL(url) else {
            webView.load(request)
            return
        }

        clearWebsiteData(for: url) { [weak self] in
            self?.webView.load(request)
        }
    }

    private func cacheBypassingRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    private func isLocalDevelopmentURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func clearWebsiteData(for url: URL, completion: @escaping () -> Void) {
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()

        dataStore.fetchDataRecords(ofTypes: types) { records in
            let matchingRecords = records.filter { record in
                record.displayName == "localhost" ||
                record.displayName == "127.0.0.1" ||
                record.displayName == "::1"
            }

            guard !matchingRecords.isEmpty else {
                DispatchQueue.main.async(execute: completion)
                return
            }

            dataStore.removeData(ofTypes: types, for: matchingRecords) {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private func processURLInput(_ input: String) -> URL {
        // If it already looks like a URL with protocol, use it
        if input.contains("://") {
            return URL(string: input) ?? URL(string: "https://\(input)")!
        }

        // If it looks like a domain (contains dot and no spaces), add https
        if input.contains(".") && !input.contains(" ") {
            return URL(string: "https://\(input)")!
        }

        // Otherwise, treat as search query
        let encodedQuery = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        return URL(string: "https://www.google.com/search?q=\(encodedQuery)")!
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    private func updateURLField(_ url: URL?) {
        if let url = url {
            currentURL = url
            urlField.stringValue = url.absoluteString
        }
    }
}

// MARK: - WKNavigationDelegate
extension BrowserPanelViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Block web content from navigating to local files; the embedded
        // browser is for http(s) dev servers and docs only.
        if let scheme = navigationAction.request.url?.scheme?.lowercased(),
           scheme == "file" {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateNavigationButtons()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateNavigationButtons()
        updateURLField(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavigationButtons()
        updateURLField(webView.url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavigationButtons()
        print("WebView navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateNavigationButtons()
        print("WebView provisional navigation failed: \(error.localizedDescription)")
    }
}

// MARK: - WKUIDelegate
extension BrowserPanelViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Handle popup windows by loading in the same web view
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Web Page Alert"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Web Page Confirmation"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Web Page Input"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = defaultText ?? ""
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            completionHandler(textField.stringValue)
        } else {
            completionHandler(nil)
        }
    }
}
