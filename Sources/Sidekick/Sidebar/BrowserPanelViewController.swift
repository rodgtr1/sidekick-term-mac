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

        preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences = preferences

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

        // Set background color
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = NSColor(hex: "#1e1e2e") ?? .controlBackgroundColor
        }

        view.addSubview(webView)
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
        webView.reload()
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
        webView.load(URLRequest(url: url))
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