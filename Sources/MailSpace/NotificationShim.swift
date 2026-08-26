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

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static let source = """
    (function () {
      if (window.__mailspaceNotifications) { return; }
      window.__mailspaceNotifications = true;

      function post(title, options) {
        options = options || {};
        try {
          window.webkit.messageHandlers.mailspaceNotify.postMessage({
            title: String(title == null ? '' : title),
            body: String(options.body == null ? '' : options.body),
            tag: String(options.tag == null ? '' : options.tag)
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
