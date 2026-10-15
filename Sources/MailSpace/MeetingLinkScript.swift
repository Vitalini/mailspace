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
/// The script reads the page's own inline event list and, only when the
/// event's record is not in it, fetches the event's page from the same origin
/// with the user's cookies. That fetch is the one request the lookup makes; a
/// response from any other origin (a signed-out redirect) is no link.
///
/// The payload is always `{ ok, url, links, fetched }`:
/// - `url` is one allow-listed string or `null`;
/// - `links` is how many distinct allow-listed URLs the event's record held;
/// - `fetched` says the record came from the fetched event page.
///
/// `MeetingLink` is the same rules in Swift, and `MAILSPACE_SELFTEST=meetinglink`
/// asserts the two agree on every fixture in `MeetingLinkFixtures`. The rules
/// are documented once, on `MeetingLink`.
enum MeetingLinkScript {
    /// `msFindMeetingLink(root, title, fetchPage)` and its helpers on their
    /// own, so the self-test runs *this* function over a parsed fixture, with a
    /// stand-in `fetchPage`, instead of a reimplementation of it.
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

    function msMeetingEventKey(id) {
      return String(id == null ? '' : id).replace(/=+$/, '');
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

    function msMeetingTextLinks(text) {
      const found = String(text).match(/\(jsRegexBody(MeetingLink.textLinkPattern))/g) || [];
      const links = [];
      for (let i = 0; i < found.length; i++) {
        let candidate = found[i];
        while (candidate.length > 0 && '\(MeetingLink.trailingPunctuation)'.indexOf(candidate.charAt(candidate.length - 1)) >= 0) {
          candidate = candidate.slice(0, -1);
        }
        if (msMeetingAllowed(candidate)) { links.push(candidate); }
      }
      return links;
    }

    function msMeetingDistinct(urls) {
      const seen = [];
      for (let i = 0; i < urls.length; i++) {
        if (seen.indexOf(urls[i]) < 0) { seen.push(urls[i]); }
      }
      return seen;
    }

    // The events the title names, as their chips spell the ids, in document
    // order and distinct up to padding.
    function msMeetingEventIds(root, wanted) {
      const ids = [];
      const nodes = msMeetingTextNodes(root);
      for (let i = 0; i < nodes.length; i++) {
        if (msMeetingNormalize(nodes[i].data) !== wanted) { continue; }
        const parent = nodes[i].parentElement;
        const chip = parent ? parent.closest('[\(MeetingLink.eventAttribute)]') : null;
        if (!chip) { continue; }
        const id = chip.getAttribute('\(MeetingLink.eventAttribute)');
        if (msMeetingEventKey(id) === '') { continue; }
        let known = false;
        for (let j = 0; j < ids.length; j++) {
          if (msMeetingEventKey(ids[j]) === msMeetingEventKey(id)) { known = true; }
        }
        if (!known) { ids.push(id); }
      }
      return ids;
    }

    // Several events with one title: a URL only when every record holds
    // exactly one link and it is the same one. Never fetched.
    function msMeetingAgreeing(perRecord) {
      let all = [];
      let agree = true;
      for (let i = 0; i < perRecord.length; i++) {
        if (perRecord[i] === null || perRecord[i].length !== 1) { agree = false; }
        if (perRecord[i] !== null) { all = all.concat(perRecord[i]); }
      }
      const union = msMeetingDistinct(all);
      agree = agree && union.length === 1;
      return { ok: true, url: agree ? union[0] : null, links: union.length, fetched: false };
    }

    function msMeetingIsEventURL(value, key) {
      const marker = '\(MeetingLink.eventURLMarker)';
      const at = value.indexOf(marker);
      if (at < 0) { return false; }
      let raw = value.slice(at + marker.length);
      const end = raw.search(/[&#]/);
      if (end >= 0) { raw = raw.slice(0, end); }
      let decoded = raw;
      try { decoded = decodeURIComponent(raw); } catch (error) { decoded = raw; }
      return msMeetingEventKey(decoded) === key;
    }

    function msMeetingMembers(value) {
      if (Array.isArray(value)) { return value; }
      return Object.keys(value).map(function (name) { return value[name]; });
    }

    function msMeetingRecords(value, key, records) {
      if (value === null || typeof value !== 'object') { return; }
      const members = msMeetingMembers(value);
      for (let i = 0; i < members.length; i++) {
        if (typeof members[i] === 'string' && msMeetingIsEventURL(members[i], key)) {
          records.push(value);
          return;
        }
      }
      for (let i = 0; i < members.length; i++) { msMeetingRecords(members[i], key, records); }
    }

    function msMeetingStrings(value, strings) {
      if (typeof value === 'string') { strings.push(value); return; }
      if (value === null || typeof value !== 'object') { return; }
      const members = msMeetingMembers(value);
      for (let i = 0; i < members.length; i++) { msMeetingStrings(members[i], strings); }
    }

    // The distinct allow-listed links of every record for `key` in the
    // document's scripts, or null when no script holds such a record.
    function msMeetingRecordLinks(root, key) {
      const records = [];
      const scripts = root.querySelectorAll('script');
      for (let i = 0; i < scripts.length; i++) {
        const text = scripts[i].textContent || '';
        if (text.indexOf('\(MeetingLink.eventListMarker)') < 0) { continue; }
        let json;
        try { json = JSON.parse(text.trim()); } catch (error) { continue; }
        msMeetingRecords(json, key, records);
      }
      if (records.length === 0) { return null; }
      const strings = [];
      for (let i = 0; i < records.length; i++) { msMeetingStrings(records[i], strings); }
      let links = [];
      for (let i = 0; i < strings.length; i++) { links = links.concat(msMeetingTextLinks(strings[i])); }
      return msMeetingDistinct(links);
    }

    function msMeetingDecide(links, fetched) {
      return { ok: true, url: links.length === 1 ? links[0] : null, links: links.length, fetched: fetched };
    }

    async function msFindMeetingLink(root, title, fetchPage) {
      const nothing = { ok: true, url: null, links: 0, fetched: false };
      const wanted = msMeetingNormalize(title);
      if (wanted === '') { return nothing; }
      const ids = msMeetingEventIds(root, wanted);
      if (ids.length === 0 || ids.length > \(MeetingLink.maxRecurringRecords)) { return nothing; }
      if (ids.length > 1) {
        const perRecord = [];
        for (let i = 0; i < ids.length; i++) { perRecord.push(msMeetingRecordLinks(root, msMeetingEventKey(ids[i]))); }
        return msMeetingAgreeing(perRecord);
      }
      const eventId = ids[0];
      const key = msMeetingEventKey(eventId);

      const local = msMeetingRecordLinks(root, key);
      if (local !== null) { return msMeetingDecide(local, false); }
      if (!/\(jsRegexBody(MeetingLink.fetchableEventIdPattern))/.test(eventId)) { return nothing; }

      let page = null;
      try { page = await fetchPage(eventId); } catch (error) { page = null; }
      const fetched = typeof page === 'string' ? new DOMParser().parseFromString(page, 'text/html') : null;
      const links = fetched ? msMeetingRecordLinks(fetched, key) : null;
      if (links === null) { return { ok: true, url: null, links: 0, fetched: true }; }
      return msMeetingDecide(links, true);
    }
    """

    /// The production body: the live Calendar document, the event page fetched
    /// from the same origin with the user's cookies, and `title` passed through
    /// `callAsyncJavaScript`'s `arguments:`.
    static let pageScript = findFunction + """


    async function msMeetingFetchPage(eventId) {
      const controller = typeof AbortController === 'function' ? new AbortController() : null;
      const timer = controller ? setTimeout(function () { controller.abort(); }, \(Int(JoinLookup.deadline * 1000))) : null;
      try {
        const response = await fetch('\(MeetingLink.eventPagePath)' + eventId, {
          credentials: 'include',
          signal: controller ? controller.signal : undefined
        });
        if (!response.ok) { return null; }
        if (new URL(response.url, location.href).origin !== location.origin) { return null; }
        return await response.text();
      } finally {
        if (timer !== null) { clearTimeout(timer); }
      }
    }

    try {
      return await msFindMeetingLink(document, title, msMeetingFetchPage);
    } catch (error) {
      return { ok: false, url: null, links: 0, fetched: false };
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
