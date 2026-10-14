#if os(macOS)
import AppKit
import Foundation
import WebKit

/// An off-screen WebKit page. It runs the same page script as Safari without needing
/// Safari or any permissions, which makes end-to-end tests repeatable.
@MainActor
public final class WebViewDriver: NSObject, ScriptedBrowserDriver, WKNavigationDelegate {
    public let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1600), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    public func load(url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    public func open(_ url: URL) async throws {
        try await load(url: url)
    }

    /// Loads HTML as if it had been served from `baseURL`, to stand in for any site.
    public func load(html: String, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    public func evaluate(_ javascript: String) async throws -> String {
        let result = try await webView.evaluateJavaScript(javascript)
        if let text = result as? String { return text }
        if let number = result as? NSNumber { return number.stringValue }
        return ""
    }

    public func currentURL() async throws -> String {
        webView.url?.absoluteString ?? ""
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}
#endif
