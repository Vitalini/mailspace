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

    // A URL only when every record (or event) holds exactly one link and it
    // is the same one.
    function msMeetingAgreeing(perRecord, fetched) {
      let all = [];
      let agree = true;
      for (let i = 0; i < perRecord.length; i++) {
        if (perRecord[i] === null || perRecord[i].length !== 1) { agree = false; }
        if (perRecord[i] !== null) { all = all.concat(perRecord[i]); }
      }
      const union = msMeetingDistinct(all);
      agree = agree && union.length === 1;
      return { ok: true, url: agree ? union[0] : null, links: union.length, fetched: fetched };
    }

    // Which series an event id belongs to, and which instance; see
    // MeetingLink.identity(of:).
    function msMeetingIdentity(eventId) {
      const key = msMeetingEventKey(eventId);
      const malformed = { series: '\(MeetingLink.malformedSeriesPrefix)' + key, timestamp: '' };
      if (!/^[A-Za-z0-9_-]+$/.test(key)) { return malformed; }
      let base64 = key.replace(/-/g, '+').replace(/_/g, '/');
      while (base64.length % 4 !== 0) { base64 += '='; }
      let text;
      try { text = atob(base64); } catch (error) { return malformed; }
      if (!/^[\\x20-\\x7e]+$/.test(text)) { return malformed; }
      const parts = text.split(' ');
      if (parts.length !== 2 || parts[0] === '' || parts[1] === '') { return malformed; }
      let base = parts[0];
      let timestamp = '';
      const at = base.lastIndexOf('_');
      if (at > 0 && /\(jsRegexBody(MeetingLink.instanceSuffixPattern))/.test(base.slice(at + 1))) {
        timestamp = base.slice(at + 1);
        base = base.slice(0, at);
      }
      return { series: base + ' ' + parts[1], timestamp: timestamp };
    }

    function msMeetingEarliest(identities) {
      let best = 0;
      for (let i = 0; i < identities.length; i++) {
        if (identities[i].timestamp < identities[best].timestamp) { best = i; }
      }
      return best;
    }

    // The event id an event-URL member names, decoded and without padding;
    // null unless the whole string is such a URL.
    function msMeetingEventIdInURL(value) {
      const prefix = '\(MeetingLink.eventURLPrefix)';
      if (value.indexOf(prefix) !== 0 || /\\s/.test(value)) { return null; }
      let raw = value.slice(prefix.length);
      const end = raw.search(/[&#]/);
      if (end >= 0) { raw = raw.slice(0, end); }
      let decoded = raw;
      try { decoded = decodeURIComponent(raw); } catch (error) { decoded = raw; }
      return msMeetingEventKey(decoded);
    }

    function msMeetingMembers(value) {
      if (Array.isArray(value)) { return value; }
      return Object.keys(value).map(function (name) { return value[name]; });
    }

    function msMeetingRecords(value, matches, records) {
      if (value === null || typeof value !== 'object') { return; }
      const members = msMeetingMembers(value);
      // A container with an event-URL member is a record. It belongs to an
      // event only when it names exactly one; a record naming two events is
      // nobody's, and is not searched further.
      const named = [];
      for (let i = 0; i < members.length; i++) {
        if (typeof members[i] !== 'string') { continue; }
        const id = msMeetingEventIdInURL(members[i]);
        if (id !== null && named.indexOf(id) < 0) { named.push(id); }
      }
      if (named.length > 0) {
        if (named.length === 1 && matches(named[0])) { records.push(value); }
        return;
      }
      for (let i = 0; i < members.length; i++) { msMeetingRecords(members[i], matches, records); }
    }

    function msMeetingStrings(value, strings) {
      if (typeof value === 'string') { strings.push(value); return; }
      if (value === null || typeof value !== 'object') { return; }
      const members = msMeetingMembers(value);
      for (let i = 0; i < members.length; i++) { msMeetingStrings(members[i], strings); }
    }

    // Every record in the document's scripts whose event id passes
    // `matches`, as that record's distinct allow-listed links.
    function msMeetingRecordLinks(root, matches) {
      const records = [];
      const scripts = root.querySelectorAll('script');
      for (let i = 0; i < scripts.length; i++) {
        const text = scripts[i].textContent || '';
        if (text.indexOf('\(MeetingLink.eventListMarker)') < 0) { continue; }
        let json;
        try { json = JSON.parse(text.trim()); } catch (error) { continue; }
        msMeetingRecords(json, matches, records);
      }
      const perRecord = [];
      for (let i = 0; i < records.length; i++) {
        const strings = [];
        msMeetingStrings(records[i], strings);
        let links = [];
        for (let j = 0; j < strings.length; j++) { links = links.concat(msMeetingTextLinks(strings[j])); }
        perRecord.push(msMeetingDistinct(links));
      }
      return perRecord;
    }

    async function msFindMeetingLink(root, title, fetchPage) {
      const nothing = { ok: true, url: null, links: 0, fetched: false };
      const fetchedNothing = { ok: true, url: null, links: 0, fetched: true };
      const wanted = msMeetingNormalize(title);
      if (wanted === '') { return nothing; }
      const ids = msMeetingEventIds(root, wanted);
      if (ids.length === 0) { return nothing; }
      const identities = ids.map(msMeetingIdentity);

      // One series: a single event, or the instances of one recurring event.
      let oneSeries = true;
      for (let i = 0; i < identities.length; i++) {
        if (identities[i].series !== identities[0].series) { oneSeries = false; }
      }
      if (oneSeries) {
        const keys = ids.map(msMeetingEventKey);
        const series = identities[0].series;
        const isOwn = function (id) { return keys.indexOf(id) >= 0; };
        const isMaster = function (id) {
          const other = msMeetingIdentity(id);
          return other.series === series && other.timestamp === '';
        };
        // An instance's own record wins over the master's: an edited instance
        // can carry a link the master no longer matches.
        const seriesRecords = function (doc) {
          const own = msMeetingRecordLinks(doc, isOwn);
          return own.length > 0 ? own : msMeetingRecordLinks(doc, isMaster);
        };
        const found = seriesRecords(root);
        if (found.length > 0) { return msMeetingAgreeing(found, false); }

        const first = ids[msMeetingEarliest(identities)];
        if (!/\(jsRegexBody(MeetingLink.fetchableEventIdPattern))/.test(first)) { return nothing; }
        let page = null;
        try { page = await fetchPage(first); } catch (error) { page = null; }
        if (typeof page !== 'string') { return fetchedNothing; }
        const fetched = seriesRecords(new DOMParser().parseFromString(page, 'text/html'));
        if (fetched.length === 0) { return fetchedNothing; }
        return msMeetingAgreeing(fetched, true);
      }

      // Several series with one title: every event must have its record,
      // and every record the same one link. Never fetched.
      if (ids.length > \(MeetingLink.maxRecurringRecords)) { return nothing; }
      // Each record is judged on its own, as in the one-series case.
      const perRecord = [];
      for (let i = 0; i < ids.length; i++) {
        const key = msMeetingEventKey(ids[i]);
        const found = msMeetingRecordLinks(root, function (id) { return id === key; });
        if (found.length === 0) { perRecord.push(null); }
        for (let j = 0; j < found.length; j++) { perRecord.push(found[j]); }
      }
      return msMeetingAgreeing(perRecord, false);
    }
    """

    /// The production body: the live Calendar document, the event page fetched
    /// from the same origin with the user's cookies, and `title` passed through
    /// `callAsyncJavaScript`'s `arguments:`.
    static let pageScript = findFunction + """


    // The event page, same-origin only, at most `fetchByteLimit` bytes, and
    // given up before Swift's deadline (`abortAfterMs`, an argument).
    async function msMeetingFetchPage(eventId) {
      const limit = \(MeetingLink.fetchByteLimit);
      const abortAfter = typeof abortAfterMs === 'number' ? abortAfterMs : \(JoinLookup.scriptAbortMilliseconds);
      const controller = typeof AbortController === 'function' ? new AbortController() : null;
      const timer = controller ? setTimeout(function () { controller.abort(); }, abortAfter) : null;
      try {
        const response = await fetch('\(MeetingLink.eventPagePath)' + eventId, {
          credentials: 'same-origin',
          redirect: 'follow',
          signal: controller ? controller.signal : undefined
        });
        if (!response.ok) { return null; }
        if (new URL(response.url, location.href).origin !== location.origin) { return null; }
        const declared = Number(response.headers.get('content-length'));
        if (declared > limit) {
          if (controller) { controller.abort(); }
          return null;
        }
        if (!response.body || typeof response.body.getReader !== 'function') {
          const text = await response.text();
          return text.length > limit ? null : text;
        }
        const reader = response.body.getReader();
        const chunks = [];
        let size = 0;
        for (;;) {
          const step = await reader.read();
          if (step.done) { break; }
          size += step.value.byteLength;
          if (size > limit) {
            try { await reader.cancel(); } catch (error) { }
            return null;
          }
          chunks.push(step.value);
        }
        const bytes = new Uint8Array(size);
        let at = 0;
        for (let i = 0; i < chunks.length; i++) { bytes.set(chunks[i], at); at += chunks[i].byteLength; }
        return new TextDecoder('utf-8').decode(bytes);
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
