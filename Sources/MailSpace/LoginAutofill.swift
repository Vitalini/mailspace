import WebKit

/// Mailplane-style sign-in assist.
///
/// macOS `WKWebView` has no password-autofill UI of its own, so MailSpace
/// fills Google's sign-in form itself: the injected script asks the native
/// side for the account's credentials and writes them into the email and
/// password fields. It never presses Next — the user submits, so 2FA and any
/// challenge screen stay entirely manual.
///
/// The script is a no-op on every host except `accounts.google.com`, so the
/// password is never handed to Gmail's or Calendar's page context.
final class LoginAutofill: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "mailspaceAutofill"

    weak var locator: SessionLocating?

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard
            message.name == Self.handlerName,
            let webView = message.webView,
            let session = locator?.session(hosting: webView),
            let account = locator?.account(for: session.accountId),
            !account.email.isEmpty
        else {
            replyHandler([String: String](), nil)
            return
        }

        var payload: [String: String] = ["email": account.email]
        if let password = KeychainStore.password(for: account.email) {
            payload["password"] = password
        }
        replyHandler(payload, nil)
    }

    private static let source = """
    (function () {
      if (window.__mailspaceAutofill) { return; }
      window.__mailspaceAutofill = true;
      if (location.hostname !== 'accounts.google.com') { return; }

      var EMAIL = 'input[type=email]:not([disabled]), input[name=identifier]:not([disabled])';
      var PASSWORD = 'input[type=password]:not([disabled])';
      var filledEmail = false;
      var filledPassword = false;
      var pending = false;

      function usable(el) {
        return !!el && !!el.offsetParent && !el.readOnly && !el.value;
      }

      function setValue(el, value) {
        var descriptor = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
        if (descriptor && descriptor.set) {
          descriptor.set.call(el, value);
        } else {
          el.value = value;
        }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }

      async function tick() {
        if (pending) { return; }
        var email = document.querySelector(EMAIL);
        var password = document.querySelector(PASSWORD);
        var wantsEmail = !filledEmail && usable(email);
        var wantsPassword = !filledPassword && usable(password);
        if (!wantsEmail && !wantsPassword) { return; }

        pending = true;
        var credentials;
        try {
          credentials = await window.webkit.messageHandlers.mailspaceAutofill.postMessage({});
        } catch (e) {
          credentials = null;
        }
        pending = false;
        if (!credentials) { return; }

        if (wantsEmail && credentials.email) {
          setValue(email, credentials.email);
          filledEmail = true;
        }
        if (wantsPassword && credentials.password) {
          setValue(password, credentials.password);
          filledPassword = true;
        }
        // Deliberately no form submit: the user presses Next, and any 2FA or
        // challenge step is handled by hand.
      }

      function start() {
        // Google's sign-in is a single-page flow: the password field appears
        // without a fresh page load, so watch the DOM rather than fill once.
        new MutationObserver(function () { tick(); })
          .observe(document.documentElement, { childList: true, subtree: true });
        tick();
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
      } else {
        start();
      }
      setInterval(tick, 1500);
    })();
    """
}
