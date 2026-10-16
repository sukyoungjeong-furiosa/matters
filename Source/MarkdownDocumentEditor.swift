import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct MarkdownDocumentEditor: NSViewRepresentable {
  let text: String
  let documentURL: URL
  let rootURL: URL
  let onEdit: (String, String) -> Void
  let workspace: Workspace
  let onOpenDocument: (URL) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    let coordinator = context.coordinator
    coordinator.onEdit = onEdit
    coordinator.onOpenDocument = onOpenDocument
    coordinator.documentURL = documentURL
    coordinator.assets.directory = documentURL.deletingLastPathComponent()
    coordinator.assets.root = rootURL
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(coordinator.assets, forURLScheme: "matters-asset")
    configuration.userContentController.add(coordinator, name: "mattersEdit")
    for resource in ["rich-editor.js"] {
      if let url = Bundle.main.url(forResource: resource, withExtension: nil),
        let script = try? String(contentsOf: url, encoding: .utf8)
      {
        configuration.userContentController.addUserScript(
          WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
      }
    }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    webView.setAccessibilityLabel("Markdown 문서 편집")
    coordinator.webView = webView
    coordinator.pendingText = text
    workspace.flushRenderedEdits = { [weak coordinator] in await coordinator?.flush() }
    workspace.renderedCommand = { [weak coordinator] name in coordinator?.command(name) }
    let html =
      Bundle.main.url(forResource: "preview.html", withExtension: nil).flatMap {
        try? String(contentsOf: $0, encoding: .utf8)
      } ?? "<p>미리보기를 불러올 수 없습니다.</p>"
    webView.loadHTMLString(html, baseURL: nil)
    return webView
  }
  func updateNSView(_ webView: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.onEdit = onEdit
    coordinator.onOpenDocument = onOpenDocument
    coordinator.documentURL = documentURL
    coordinator.assets.directory = documentURL.deletingLastPathComponent()
    coordinator.assets.root = rootURL
    if coordinator.pendingText != text {
      coordinator.pendingText = text
      coordinator.render()
    }
  }
  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    Task { @MainActor in
      await coordinator.flush()
      webView.stopLoading()
      webView.configuration.userContentController.removeScriptMessageHandler(forName: "mattersEdit")
      webView.navigationDelegate = nil
    }
  }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var webView: WKWebView?
    var documentURL: URL?
    let assets = MarkdownAssets()
    var pendingText = ""
    private var renderedText: String?
    private var ready = false
    var onEdit: ((String, String) -> Void)?
    var onOpenDocument: ((URL) -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      ready = true
      render()
    }
    func render() {
      guard ready, let webView, let documentURL, renderedText != pendingText else { return }
      let source = pendingText
      webView.callAsyncJavaScript(
        "window.renderMarkdown(source, identity)",
        arguments: ["source": source, "identity": documentURL.path], in: nil, in: .page
      ) { [weak self] result in
        if case .success = result { self?.renderedText = source }
      }
    }
    func accept(base: String, value: String) {
      guard base == pendingText, value != base else { return }
      pendingText = value
      renderedText = value
      onEdit?(base, value)
    }
    func flush() async {
      guard ready, let webView else { return }
      let base = pendingText
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        var finished = false
        func finish() {
          if !finished {
            finished = true
            continuation.resume()
          }
        }
        // WebKit may already be tearing down its process during quit.
        // A final bridge request must never prevent the app terminating.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { finish() }
        webView.callAsyncJavaScript(
          "return window.mattersSource()", arguments: [:], in: nil, in: .page
        ) { [weak self] result in
          if !finished, case .success(let value as String) = result {
            self?.accept(base: base, value: value)
          }
          finish()
        }
      }
    }
    func command(_ name: String) {
      webView?.callAsyncJavaScript(
        "window.mattersEditor.chain().focus()[name]().run()", arguments: ["name": name], in: nil,
        in: .page
      ) { _ in }
    }
    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.name == "mattersEdit", message.frameInfo.isMainFrame,
        let body = message.body as? [String: String], body["identity"] == documentURL?.path
      else { return }
      if let href = body["href"] {
        if let url = URL(string: href),
          ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
        {
          NSWorkspace.shared.open(url)
        } else if let url = URL(string: "matters-asset://document/" + href),
          let local = assets.localURL(for: url)
        {
          onOpenDocument?(local)
        }
        return
      }
      guard let base = body["base"], let value = body["markdown"] else { return }
      accept(base: base, value: value)
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      if navigationAction.navigationType == .linkActivated {
        if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
          NSWorkspace.shared.open(url)
        } else if let local = assets.localURL(for: url) {
          onOpenDocument?(local)
        }
        decisionHandler(.cancel)
      } else {
        decisionHandler(url.scheme == "about" ? .allow : .cancel)
      }
    }
  }
}

final class MarkdownAssets: NSObject, WKURLSchemeHandler {
  var directory = URL(fileURLWithPath: "/")
  var root = URL(fileURLWithPath: "/")
  func localURL(for url: URL) -> URL? {
    guard url.scheme == "matters-asset", url.host == "document" else { return nil }
    let local = FileStore.canonical(directory.appendingPathComponent(String(url.path.dropFirst())))
    guard local.path.hasPrefix(FileStore.canonical(root).path + "/") else { return nil }
    return local
  }
  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let request = urlSchemeTask.request.url, let url = localURL(for: request),
      let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
      let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      info.isRegularFile == true, (info.fileSize ?? 0) <= 20_000_000,
      let data = try? Data(contentsOf: url)
    else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    urlSchemeTask.didReceive(
      URLResponse(
        url: request, mimeType: type.preferredMIMEType, expectedContentLength: data.count,
        textEncodingName: nil))
    urlSchemeTask.didReceive(data)
    urlSchemeTask.didFinish()
  }
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
