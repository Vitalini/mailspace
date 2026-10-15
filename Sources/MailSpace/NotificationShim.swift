import WebKit

/// The JavaScript that turns web notifications into native ones.
///
/// Gmail and Google Calendar ask for the Web Notification API and then post
/// through it. WebKit in an app has no notification UI of its own, so the shim
/// replaces `Notification` with a stand-in that reports every notification to
/// the native side, and grants permission outright so Gmail's own "Desktop
/// notifications" setting can be switched on.
///
/// It ships as a Swift string rather than a resource file — the app bundle is
/// hand-assembled and has no resource-bundle plumbing.
enum NotificationShim {
    static let handlerName = "mailspaceNotify"

    /// Main frame only, like `LoginAutofill`. `NotificationOrigin.isTrusted`
    /// opens by rejecting every subframe, so a shim running in an iframe could
    /// never produce a notification that was accepted — it only cost a script
    /// evaluation in every third-party frame Gmail embeds, and left
    /// `window.webkit.messageHandlers.mailspaceNotify` reachable from them.
    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private static let source = """
    (function () {
      if (window.__mailspaceNotifications) { return; }
      window.__mailspaceNotifications = true;

      // Key names only, never values: the R32 diagnostic line wants to know
      // what Calendar passes, not what it says. Each helper is wrapped so an
      // odd or hostile object (a throwing getter, a proxy) costs the extra
      // fields and never the notification.
      function keysOf(value) {
        try {
          if (value && typeof value === 'object') {
            return Object.keys(value).slice(0, 20).map(String);
          }
        } catch (e) {}
        return [];
      }

      function countActions(options) {
        try {
          return Array.isArray(options.actions) ? options.actions.length : 0;
        } catch (e) {
          return 0;
        }
      }

      // The one first-level string in `data` that names a meeting host, or
      // null when there is none or more than one distinct such string. Only
      // this one string crosses; `data` itself never does. Swift re-checks it
      // against the full allow-list before it is used.
      var meetingHost = /^https:\\/\\/(meet\\.google\\.com|([a-z0-9-]+\\.)*zoom\\.us|teams\\.microsoft\\.com)\\//;
      function meetingLinkIn(data) {
        try {
          if (!data || typeof data !== 'object') { return null; }
          var keys = Object.keys(data);
          var found = null;
          for (var i = 0; i < keys.length && i < 50; i++) {
            var value;
            try { value = data[keys[i]]; } catch (e) { continue; }
            if (typeof value !== 'string' || !meetingHost.test(value)) { continue; }
            if (found === null) {
              found = value;
            } else if (found !== value) {
              return null;
            }
          }
          return found;
        } catch (e) {
          return null;
        }
      }

      function post(title, options) {
        options = options || {};
        var data = null;
        try { data = options.data; } catch (e) {}
        try {
          window.webkit.messageHandlers.mailspaceNotify.postMessage({
            title: String(title == null ? '' : title),
            body: String(options.body == null ? '' : options.body),
            tag: String(options.tag == null ? '' : options.tag),
            // The page already knows when it does not want to make noise —
            // which is why MailSpace has no sound picker of its own.
            silent: !!options.silent,
            optionKeys: keysOf(options),
            dataKeys: keysOf(data),
            actionCount: countActions(options),
            dataLink: meetingLinkIn(data)
          });
        } catch (e) {
          // A page without the handler (or a sandboxed frame) simply gets no
          // notification rather than a thrown error inside Gmail.
        }
      }

      // A plain constructor function, not a class: Gmail calls Notification
      // both with and without `new`, and a class throws on the latter.
      function MailSpaceNotification(title, options) {
        if (!(this instanceof MailSpaceNotification)) {
          return new MailSpaceNotification(title, options);
        }
        options = options || {};
        this.title = title;
        this.body = options.body || '';
        this.tag = options.tag || '';
        this.icon = options.icon || '';
        this.data = options.data;
        this.silent = !!options.silent;
        this.onclick = null;
        this.onclose = null;
        this.onerror = null;
        this.onshow = null;
        post(title, options);

        var notification = this;
        setTimeout(function () {
          if (typeof notification.onshow === 'function') {
            try { notification.onshow(); } catch (e) {}
          }
        }, 0);
      }

      MailSpaceNotification.prototype.close = function () {
        if (typeof this.onclose === 'function') {
          try { this.onclose(); } catch (e) {}
        }
      };
      MailSpaceNotification.prototype.addEventListener = function () {};
      MailSpaceNotification.prototype.removeEventListener = function () {};
      MailSpaceNotification.prototype.dispatchEvent = function () { return true; };

      MailSpaceNotification.permission = 'granted';
      // Stays 0. The page's own `actions` are not forwarded and no click can
      // be routed back to the page, so a non-zero value would invite buttons
      // that never render or that do nothing. MailSpace's native buttons
      // (Copy Code, Join) do not depend on it.
      MailSpaceNotification.maxActions = 0;
      MailSpaceNotification.requestPermission = function (callback) {
        if (typeof callback === 'function') {
          try { callback('granted'); } catch (e) {}
        }
        return Promise.resolve('granted');
      };

      try {
        Object.defineProperty(window, 'Notification', {
          value: MailSpaceNotification,
          writable: true,
          configurable: true
        });
      } catch (e) {
        window.Notification = MailSpaceNotification;
      }

      // Calendar reminders arrive through the service worker registration.
      // Overriding the prototype catches the page-side call; a notification
      // raised entirely inside a worker's own global scope is out of reach of
      // an injected script and would need the feed-diff fallback instead.
      if (window.ServiceWorkerRegistration && window.ServiceWorkerRegistration.prototype) {
        window.ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
          post(title, options);
          return Promise.resolve();
        };
        window.ServiceWorkerRegistration.prototype.getNotifications = function () {
          return Promise.resolve([]);
        };
      }

      if (navigator.permissions && navigator.permissions.query) {
        var query = navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = function (descriptor) {
          if (descriptor && descriptor.name === 'notifications') {
            return Promise.resolve({ state: 'granted', onchange: null });
          }
          return query(descriptor);
        };
      }
    })();
    """
}
