import Foundation

/// The JavaScript that actually reads the agenda, and the only place that ever
/// sees its text.
///
/// The response holds meeting titles, attendees and links. Parsing it in the
/// page and returning three numbers is what makes it structurally impossible
/// for any of that to reach Swift — and therefore `Log`, a crash report,
/// `accounts.json` or the console (KTD-S14, S22). A future edit that returns a
/// string breaks the contract visibly, right here.
///
/// The payload is always `{ ok, status, startsInSeconds, remainingCount }`:
/// - `status` is an `AgendaOutcome` raw value.
/// - `startsInSeconds` is `null` when today holds nothing more.
/// - `remainingCount` counts events still to start today.
///
/// `AgendaParser` is the same rules in Swift, and `MAILSPACE_SELFTEST=agenda`
/// asserts the two agree on every fixture.
enum AgendaScript {
    /// `msParseAgenda(html, nowMs)` — the parse half, on its own, so the
    /// self-test can run *this* function over a fixture instead of a
    /// reimplementation of it.
    static let parseFunction = """
    function msAgendaText(node) {
      return ((node && node.textContent) || '')
        .replace(/\\u00a0/g, ' ')
        .replace(/\\s+/g, ' ')
        .trim();
    }

    function msAgendaClock(text) {
      const match = /^([0-9]{1,2})(?::([0-9]{2}))?\\s*([ap])\\.?m\\.?$/.exec(text.toLowerCase());
      if (!match) { return null; }
      const hour12 = parseInt(match[1], 10);
      if (!(hour12 >= 1 && hour12 <= 12)) { return null; }
      const minute = match[2] === undefined ? 0 : parseInt(match[2], 10);
      if (!(minute >= 0 && minute <= 59)) { return null; }
      const pm = match[3] === 'p';
      const hour = pm ? (hour12 === 12 ? 12 : hour12 + 12) : (hour12 === 12 ? 0 : hour12);
      return { hour: hour, minute: minute };
    }

    function msAgendaHeaderDate(text) {
      const match = /^(?:[a-z]{3,9},?\\s+)?([a-z]{3,9})\\s+([0-9]{1,2}),?\\s+([0-9]{4})$/
        .exec(text.toLowerCase());
      if (!match) { return null; }
      const months = ['january', 'february', 'march', 'april', 'may', 'june',
                      'july', 'august', 'september', 'october', 'november', 'december'];
      const name = match[1];
      let month = 0;
      for (let i = 0; i < months.length; i++) {
        if (months[i] === name || (name.length === 3 && months[i].indexOf(name) === 0)) {
          month = i + 1;
          break;
        }
      }
      if (month === 0) { return null; }
      const day = parseInt(match[2], 10);
      if (!(day >= 1 && day <= 31)) { return null; }
      return { year: parseInt(match[3], 10), month: month, day: day };
    }

    function msParseAgenda(html, nowMs) {
      const nothing = function (status) {
        return { ok: status === 0, status: status, startsInSeconds: null, remainingCount: 0 };
      };
      let doc;
      try {
        doc = new DOMParser().parseFromString(html, 'text/html');
      } catch (error) {
        return nothing(4);
      }
      // A 200 is not an agenda: the endpoint answers a request it does not like
      // with a marketing page, status 200 (KTD-S13).
      if (!doc || !doc.querySelector('.view-container')) { return nothing(4); }

      const sections = doc.querySelectorAll('.date-section');
      // A day with nothing on it renders no section at all. That is an answer.
      if (sections.length === 0) { return nothing(0); }
      if (sections.length !== 1) { return nothing(4); }
      const section = sections[0];

      const header = section.querySelector('.date');
      if (!header) { return nothing(4); }
      const day = msAgendaHeaderDate(msAgendaText(header));
      if (!day) { return nothing(4); }

      const now = new Date(nowMs);
      if (day.year !== now.getFullYear() || day.month !== now.getMonth() + 1 || day.day !== now.getDate()) {
        return nothing(4);
      }

      const rows = section.querySelectorAll('.event');
      const starts = [];
      for (let i = 0; i < rows.length; i++) {
        const cell = rows[i].querySelector('.event-time');
        const text = cell ? msAgendaText(cell) : '';
        // No start time means an all-day event: nothing to count down to.
        if (text === '') { continue; }
        const clock = msAgendaClock(text);
        // One unreadable time fails the whole document. Skipping it would count
        // down to the second meeting instead.
        if (!clock) { return nothing(4); }
        starts.push(new Date(day.year, day.month - 1, day.day, clock.hour, clock.minute, 0, 0).getTime());
      }

      const remaining = starts.filter(function (t) { return t > now.getTime(); }).sort(function (a, b) { return a - b; });
      if (remaining.length === 0) { return nothing(0); }
      return {
        ok: true,
        status: 0,
        startsInSeconds: Math.floor((remaining[0] - now.getTime()) / 1000),
        remainingCount: remaining.length
      };
    }
    """

    /// The whole production script: fetch `path` same-origin, then parse it in
    /// the page.
    ///
    /// `path` and `nowMs` arrive through `callAsyncJavaScript`'s `arguments:`,
    /// never by string interpolation — the account's own calendar address goes
    /// into the URL and it is not going into a JS source string.
    ///
    /// The host check first: a signed-out account sits on `accounts.google.com`,
    /// where the fetch would be cross-origin. That is a definite "nothing to
    /// show", not a failed check, and reporting it as a failure is what leaves a
    /// stale number on a tab forever.
    static let fetchScript = parseFunction + """


    if (!/^calendar\\.google\\.com$/.test(location.hostname)) {
      return { ok: false, status: 1, startsInSeconds: null, remainingCount: 0 };
    }
    const controller = new AbortController();
    const deadline = setTimeout(function () { controller.abort(); }, 20000);
    try {
      const response = await fetch(path, {
        credentials: 'include',
        cache: 'no-store',
        signal: controller.signal
      });
      if (!response.ok) {
        // 4xx is an answer — this calendar is not readable this way, so the
        // cached value is dropped. 5xx and everything else is no answer at all.
        const definite = response.status >= 400 && response.status < 500;
        return { ok: false, status: definite ? 2 : 3, startsInSeconds: null, remainingCount: 0 };
      }
      return msParseAgenda(await response.text(), nowMs);
    } catch (error) {
      return { ok: false, status: 3, startsInSeconds: null, remainingCount: 0 };
    } finally {
      clearTimeout(deadline);
    }
    """
}
