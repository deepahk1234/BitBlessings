//
// BlessingsView.swift
// bitchat
//
// Hosts the Blessings HTML/JS UI inside a WKWebView with a bidirectional bridge.
// The bridge allows JS to send blessing questions/responses via bitchat mesh,
// and Swift to push live vote updates back to the JS.
//

import SwiftUI
import WebKit
import Combine

// MARK: - JS Message Handler Names
private enum JSBridge {
    static let sendQuestion  = "sendBlessingQuestion"   // JS → Swift: broadcast a question
    static let sendResponse  = "sendBlessingResponse"   // JS → Swift: broadcast yes/no/wait
    static let ready         = "blessingReady"          // JS → Swift: WebView finished loading
}

// MARK: - Coordinator (WKScriptMessageHandler + WKNavigationDelegate)

final class BlessingsWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    weak var webView: WKWebView?
    var transport: Transport?
    var myNicknameProvider: (() -> String)?

    private let blessingsService = BlessingsService.shared

    override init() {
        super.init()
        // Wire the JS callback so BlessingsService can push updates to the webview
        blessingsService.onJSEvent = { [weak self] js in
            DispatchQueue.main.async {
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }

        switch message.name {

        case JSBridge.sendQuestion:
            guard let text = body["question"] as? String, !text.isEmpty,
                  let transport = transport else { return }
            let nickname = myNicknameProvider?() ?? "anon"
            blessingsService.configure(nickname: nickname)
            blessingsService.broadcastQuestion(text, transport: transport)

        case JSBridge.sendResponse:
            guard let questionId = body["questionId"] as? String,
                  let responseStr = body["response"] as? String,
                  let response = BlessingResponse(rawValue: responseStr),
                  let transport = transport else { return }
            let nickname = myNicknameProvider?() ?? "anon"
            blessingsService.configure(nickname: nickname)
            blessingsService.broadcastResponse(questionId: questionId, response: response, transport: transport)

        case JSBridge.ready:
            // WebView is ready — sync current nickname and all known questions
            let nickname = myNicknameProvider?() ?? "anon"
            let js = "window.setMyNickname && window.setMyNickname('\(escapeJS(nickname))');"
            webView?.evaluateJavaScript(js, completionHandler: nil)
            blessingsService.syncAllQuestionsToJS()

        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Inject nickname and existing state after navigation
        let nickname = myNicknameProvider?() ?? "anon"
        let js = "window.setMyNickname && window.setMyNickname('\(escapeJS(nickname))');"
        webView.evaluateJavaScript(js, completionHandler: nil)
        blessingsService.syncAllQuestionsToJS()
    }

    private func escapeJS(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
    }
}

// MARK: - BlessingsWebView (platform-adaptive WKWebView wrapper)

#if os(iOS)
struct BlessingsWebView: UIViewRepresentable {
    let coordinator: BlessingsWebCoordinator
    let url: URL

    func makeCoordinator() -> BlessingsWebCoordinator { coordinator }

    func makeUIView(context: Context) -> WKWebView {
        let webView = buildWebView(coordinator: coordinator)
        coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        loadURLIfNeeded(webView, url: url)
    }
}
#elseif os(macOS)
struct BlessingsWebView: NSViewRepresentable {
    let coordinator: BlessingsWebCoordinator
    let url: URL

    func makeCoordinator() -> BlessingsWebCoordinator { coordinator }

    func makeNSView(context: Context) -> WKWebView {
        let webView = buildWebView(coordinator: coordinator)
        coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadURLIfNeeded(webView, url: url)
    }
}
#endif

// MARK: - Shared helpers

private func buildWebView(coordinator: BlessingsWebCoordinator) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

    let contentController = WKUserContentController()
    contentController.add(coordinator, name: JSBridge.sendQuestion)
    contentController.add(coordinator, name: JSBridge.sendResponse)
    contentController.add(coordinator, name: JSBridge.ready)
    config.userContentController = contentController

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = coordinator

    #if os(iOS)
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = true
    #else
    webView.setValue(false, forKey: "drawsBackground")
    #endif

    return webView
}

private func loadURLIfNeeded(_ webView: WKWebView, url: URL) {
    // Only load if not already showing this URL
    if webView.url != url {
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}

// MARK: - BlessingsView (main SwiftUI view)

struct BlessingsView: View {

    // Transport injected from the parent (ContentView / ChatViewModel)
    var transport: Transport?

    // My current nickname from the chat system
    var myNickname: String

    @State private var webURL: URL?
    @State private var coordinator: BlessingsWebCoordinator?
    @State private var cancellables: Set<AnyCancellable> = []
    @State private var toastMessage: String? = nil

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            VStack(spacing: 0) {
                // WebView
                if let url = webURL, let coord = coordinator {
                    BlessingsWebView(coordinator: coord, url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .purple))
                            .scaleEffect(1.5)
                        Text("Loading Blessings...")
                            .foregroundColor(.gray)
                            .font(.subheadline)
                    }
                    Spacer()
                }
            }

            // Toast notification for incoming questions
            if let toast = toastMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.fill")
                            .foregroundColor(.yellow)
                        Text(toast)
                            .foregroundColor(.white)
                            .font(.footnote)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.15).opacity(0.96))
                    .clipShape(Capsule())
                    .shadow(radius: 8)
                    .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            setupCoordinator()
            loadContent()
            observeIncomingQuestions()
        }
        .onDisappear {
            cancellables.removeAll()
        }
        .onChange(of: myNickname) { newNickname in
            coordinator?.myNicknameProvider = { newNickname }
            BlessingsService.shared.configure(nickname: newNickname)
        }
    }

    // MARK: - Setup

    private func setupCoordinator() {
        let coord = BlessingsWebCoordinator()
        coord.transport = transport
        coord.myNicknameProvider = { [myNickname] in myNickname }
        BlessingsService.shared.configure(nickname: myNickname)
        coordinator = coord
    }

    private func loadContent() {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "blessings") {
            self.webURL = url
            return
        }
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            self.webURL = url
            return
        }
        print("ERROR: Could not find blessings/index.html in bundle.")
    }

    private func observeIncomingQuestions() {
        BlessingsService.shared.$newQuestionReceived
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [self] question in
                showToast("🙏 \(question.askerNickname) asks: \"\(question.question.prefix(60))\"")
            }
            .store(in: &cancellables)
    }

    private func showToast(_ message: String) {
        withAnimation {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation {
                toastMessage = nil
            }
        }
    }
}
