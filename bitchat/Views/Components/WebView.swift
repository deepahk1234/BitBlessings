//
// WebView.swift
// bitchat
//

import SwiftUI
import WebKit

#if os(iOS)
struct WebView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> WKWebView {
        return createWebView()
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
    }
}
#elseif os(macOS)
struct WebView: NSViewRepresentable {
    let url: URL
    
    func makeNSView(context: Context) -> WKWebView {
        return createWebView()
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
    }
}
#endif

// Shared helper to create the web view configuration
private func createWebView() -> WKWebView {
    let webConfiguration = WKWebViewConfiguration()
    // Allow local file access if needed
    webConfiguration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
    
    let webView = WKWebView(frame: .zero, configuration: webConfiguration)
    
    #if os(iOS)
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = true
    #else
    webView.setValue(false, forKey: "drawsBackground") // macOS transparent background
    #endif
    
    return webView
}
