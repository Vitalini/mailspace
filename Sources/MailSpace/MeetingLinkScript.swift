import Foundation

/// The JavaScript that finds a Calendar reminder's meeting link in the page.
///
/// **A narrow exception to S22 (KTD-S14), on KTD16's terms.** The agenda rule
/// says only numbers cross from a Calendar script to Swift. This script returns
/// at most one string: a URL that passed the meeting allow-list, and only at
/// notification time. The title goes page-ward as a `callAsyncJavaScript`
/// argument, never interpolated into source, and never comes back. The URL is
/// never logged; it is kept only in that notification's `userInfo`, which
/// Notification Center stores until the notification is removed. A Zoom link
/// can carry its passcode, so that is new data at rest — accepted, because it
/// is the user's own invite on the user's own Mac. The agenda poller is not
/// covered by this exception and still returns numbers only.
///
/// The payload is always `{ ok, url, links, fallback }`:
/// - `url` is one allow-listed string or `null`;
/// - `links` is how many distinct allow-listed URLs the deciding tier found;
/// - `fallback` says the title was found outside every event container.
///
/// `MeetingLink` is the same rules in Swift, and `MAILSPACE_SELFTEST=meetinglink`
/// asserts the two agree on every fixture in `MeetingLinkFixtures`. The rules
/// are documented once, on `MeetingLink`.
enum MeetingLinkScript {
    /// `msFindMeetingLink(root, title)` on its own, so the self-test runs *this*
    /// function over a parsed fixture instead of a reimplementation of it.
    static let findFunction = """
    function msMeetingAllowed(url) {
      const patterns = [\(MeetingLink.allowPatterns.map(jsRegexLiteral).joined(separator: ", "))];
      for (let i = 0; i < patterns.length; i++) {
        if (patterns[i].test(url)) { return true; }
      }
      return false;
    }

    function msMeetingNormalize(text) {
      return String(text == null ? '' : text).replace(/\\u00a0/g, ' ').replace(/\\s+/g, ' ').trim();
    }

    function msMeetingTextNodes(element) {
      const doc = element.ownerDocument || element;
      const walker = doc.createTreeWalker(element, NodeFilter.SHOW_TEXT);
      const nodes = [];
      let node;
      while ((node = walker.nextNode())) {
        const parent = node.parentNode;
        const name = parent && parent.nodeName ? parent.nodeName.toLowerCase() : '';
        if (name === 'script' || name === 'style') { continue; }
        nodes.push(node);
      }
      return nodes;
    }

    function msMeetingLinks(element) {
      const candidates = [];
      const anchors = Array.prototype.slice.call(element.querySelectorAll('a[href]'));
      if (element.matches && element.matches('a[href]')) { anchors.unshift(element); }
      for (let i = 0; i < anchors.length; i++) {
        candidates.push(anchors[i].getAttribute('href').trim());
      }
      const textNodes = msMeetingTextNodes(element);
      for (let i = 0; i < textNodes.length; i++) {
        const found = textNodes[i].data.match(/\(jsRegexBody(MeetingLink.textLinkPattern))/g) || [];
        for (let j = 0; j < found.length; j++) {
          let candidate = found[j];
          while (candidate.length > 0 && '\(MeetingLink.trailingPunctuation)'.indexOf(candidate.charAt(candidate.length - 1)) >= 0) {
            candidate = candidate.slice(0, -1);
          }
          candidates.push(candidate);
        }
      }
      return candidates.filter(msMeetingAllowed);
    }

    function msMeetingDistinct(urls) {
      const seen = [];
      for (let i = 0; i < urls.length; i++) {
        if (seen.indexOf(urls[i]) < 0) { seen.push(urls[i]); }
      }
      return seen;
    }

    function msFindMeetingLink(root, title) {
      const nothing = { ok: true, url: null, links: 0, fallback: false };
      const wanted = msMeetingNormalize(title);
      if (wanted === '') { return nothing; }
      const eventSelector = '[\(MeetingLink.eventAttribute)]';
      const textNodes = msMeetingTextNodes(root);
      const matching = textNodes.filter(function (node) { return msMeetingNormalize(node.data) === wanted; });

      // Tier 1: event containers.
      const events = [];
      for (let i = 0; i < matching.length; i++) {
        const parent = matching[i].parentElement;
        const event = parent ? parent.closest(eventSelector) : null;
        if (event && events.indexOf(event) < 0) { events.push(event); }
      }
      let collected = [];
      for (let i = 0; i < events.length; i++) { collected = collected.concat(msMeetingLinks(events[i])); }
      const tierOne = msMeetingDistinct(collected);
      if (tierOne.length > 0) {
        return { ok: true, url: tierOne.length === 1 ? tierOne[0] : null, links: tierOne.length, fallback: false };
      }

      // Tier 2: a bounded look around the title, outside every event.
      const bearers = [];
      for (let i = 0; i < matching.length; i++) {
        const parent = matching[i].parentElement;
        if (parent && bearers.indexOf(parent) < 0) { bearers.push(parent); }
      }
      const labelled = root.querySelectorAll('[aria-label]');
      for (let i = 0; i < labelled.length; i++) {
        if (msMeetingNormalize(labelled[i].getAttribute('aria-label')) === wanted && bearers.indexOf(labelled[i]) < 0) {
          bearers.push(labelled[i]);
        }
      }
      let found = [];
      for (let i = 0; i < bearers.length; i++) {
        const bearer = bearers[i];
        if (bearer.closest(eventSelector)) { continue; }
        if (bearer.closest('[hidden], [aria-hidden="true"]')) { continue; }
        let scope = bearer;
        for (let climbed = 0; scope && climbed <= \(MeetingLink.fallbackDepth); climbed++) {
          const name = scope.nodeName.toLowerCase();
          if (name === 'html' || name === 'head' || name === 'body') { break; }
          if (scope.querySelector(eventSelector)) { break; }
          const here = msMeetingLinks(scope);
          if (here.length > 0) {
            found = found.concat(here);
            break;
          }
          scope = scope.parentElement;
        }
      }
      const tierTwo = msMeetingDistinct(found);
      if (tierTwo.length === 0) { return nothing; }
      return { ok: true, url: tierTwo.length === 1 ? tierTwo[0] : null, links: tierTwo.length, fallback: true };
    }
    """

    /// The production body: the live Calendar document, with `title` passed
    /// through `callAsyncJavaScript`'s `arguments:`.
    static let pageScript = findFunction + """


    try {
      return msFindMeetingLink(document, title);
    } catch (error) {
      return { ok: false, url: null, links: 0, fallback: false };
    }
    """

    /// A Swift pattern as a JS regex literal body. Interpolated text is
    /// inserted as is, so only `/` needs escaping: the pattern is carried
    /// verbatim and the two twins cannot drift apart.
    private static func jsRegexBody(_ pattern: String) -> String {
        pattern.replacingOccurrences(of: "/", with: "\\/")
    }

    private static func jsRegexLiteral(_ pattern: String) -> String {
        "/" + jsRegexBody(pattern) + "/"
    }
}
