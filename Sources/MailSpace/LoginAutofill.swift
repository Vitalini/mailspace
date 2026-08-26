import WebKit

/// Mailplane-style sign-in assist.
///
/// macOS `WKWebView` has no password-autofill UI of its own, so MailSpace
/// fills Google's sign-in form itself: the injected script asks the native
/// side for the account's credentials and writes them into the email and
/// password fields. It never presses Next — the user submits, so 2FA and any
/// challenge screen stay entirely manual.
///
/// Two things keep the password off every page that is not Google's sign-in,
/// and the page-side hostname check is neither of them — it runs in the page,
/// so it protects nothing a hostile script cannot skip:
///
/// - the handler is registered in a **dedicated content world**, so
///   `window.webkit.messageHandlers.mailspaceAutofill` does not exist for any
///   script the page itself runs;
/// - the handler **checks the asking frame's own security origin** before it
///   touches the Keychain, so even a script that did reach it gets nothing
///   unless it is the top frame of `https://accounts.google.com`.
final class LoginAutofill: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "mailspaceAutofill"

    /// The isolated world the assist runs in.
    ///
    /// Isolated worlds share the document but not the JavaScript globals, so
    /// the script can still read and fill Google's form while page scripts see
    /// neither it nor the message handler registered alongside it. Registering
    /// in `.page` — which is what this used to do — exposed the handler to
    /// every frame of every page an account webview loads.
    static let contentWorld = WKContentWorld.world(name: "MailSpaceAutofill")

    weak var locator: SessionLocating?

    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
        super.init()
    }

    /// The registration, world included, so no caller can put the handler in
    /// the page's world by accident.
    var registration: ScriptReplyHandler {
        ScriptReplyHandler(name: Self.handlerName, handler: self, contentWorld: Self.contentWorld)
    }

    static var userScript: WKUserScript {
        // Main frame only: the handler answers no other frame anyway, so
        // injecting into subframes would only widen the surface.
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: contentWorld
        )
    }

    /// Whether a frame may be handed the account's Google password.
    ///
    /// Exact host, https, default port, top frame — nothing else. In
    /// particular `lh3.googleusercontent.com` is allow-listed for in-app
    /// navigation (`LinkRouter`), so "some Google-ish host" would not be a
    /// meaningful bar. Pure so it can be tested without a live frame.
    static func isTrustedOrigin(scheme: String, host: String, port: Int, isMainFrame: Bool) -> Bool {
        guard isMainFrame else { return false }
        guard scheme.lowercased() == "https" else { return false }
        guard host.lowercased() == "accounts.google.com" else { return false }
        // WebKit reports 0 for a scheme's own default port.
        return port == 0 || port == 443
    }

    static func isTrustedOrigin(_ frame: WKFrameInfo) -> Bool {
        let origin = frame.securityOrigin
        return isTrustedOrigin(
            scheme: origin.protocol,
            host: origin.host,
            port: origin.port,
            isMainFrame: frame.isMainFrame
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard
            message.name == Self.handlerName,
            // The `DisableSignInAutofill` valve (KTD-S6), on the native side
            // where it means something. The page-side hostname test protects
            // nothing and is not where an off switch belongs.
            !settings.disableSignInAutofill,
            Self.isTrustedOrigin(message.frameInfo),
            let webView = message.webView,
            let session = locator?.session(hosting: webView),
            let account = locator?.account(for: session.accountId),
            !account.email.isEmpty
        else {
            // Nothing, and nothing logged either: the caller is not entitled to
            // know whether an account or a stored password exists.
            replyHandler([String: String](), nil)
            return
        }

        var payload: [String: String] = ["email": account.email]
        if let password = KeychainStore.shared.password(for: account.email) {
            payload["password"] = password
        }
        replyHandler(payload, nil)
    }

    private static let source = """
    (function () {
      if (window.__mailspaceAutofill) { return; }
      window.__mailspaceAutofill = true;
      // Belt to the native side's braces: the handler checks the frame's real
      // security origin, so this only saves the pointless work elsewhere.
      if (location.hostname !== 'accounts.google.com') { return; }

      var EMAIL = '#identifierId, input[type=email]:not([disabled]), input[name="identifier"]:not([disabled])';
      var PASSWORD = 'input[type=password]:not([disabled]), input[name="Passwd"]:not([disabled])';
      var filledEmail = false;
      var filledPassword = false;
      var pending = false;

      function usable(el) {
        // offsetParent is null for anything inside a fixed-position ancestor,
        // which Google's sign-in card sometimes is — measure rects instead.
        return !!el && !el.disabled && !el.readOnly && !el.value
          && el.getClientRects().length > 0;
      }

      function setValue(el, value) {
        var descriptor = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
        if (descriptor && descriptor.set) {
          descriptor.set.call(el, value);
        } else {
          el.value = value;
        }
        // Google's form is React-driven: it only notices a value that arrives
        // through the native setter followed by real input events, and only
        // then does Next become enabled.
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true }));
        el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
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
          try { email.focus(); } catch (e) {}
        }
        if (wantsPassword && credentials.password) {
          setValue(password, credentials.password);
          filledPassword = true;
          try { password.focus(); } catch (e) {}
        }
        window.__mailspaceFilled = { email: filledEmail, password: filledPassword };
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
