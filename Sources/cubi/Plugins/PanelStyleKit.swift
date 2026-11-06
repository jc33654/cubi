import Foundation

/// The dashboard look any tool plugin's panel can ask for with `"panel": {"style": "cubi"}`:
/// one `<style>` put first in the document (so the page's own rules still win), and
/// `window.cubiIcon(name)` for a few line icons. Light and dark follow the system. Every class
/// starts with `cubi-`; the base rules (body, buttons, inputs, tables) only reach pages that asked.
/// A `cubi-tip`'s `title` shows in a bubble of the kit's own on hover, and stays on a click: the
/// system's tooltip is not reliable in Cubi's windows.
enum PanelStyleKit {
    static let script = """
    (function () {
      var s = document.createElement('style');
      s.id = 'cubi-style';
      s.textContent = \(jsString(css));
      (document.head || document.documentElement).prepend(s);
      var paths = \(icons);
      window.cubiIcon = function (name, size) {
        var d = paths[name];
        if (!d) return '';
        var n = size || 16;
        return '<svg class="cubi-icon" width="' + n + '" height="' + n + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + d + '</svg>';
      };
      var bubble = null;
      function hide() { if (bubble) { bubble.remove(); bubble = null; } }
      function show(t, pin) {
        if (t.hasAttribute('title')) { t.dataset.tip = t.title; t.setAttribute('aria-label', t.title); t.removeAttribute('title'); }
        if (!bubble || bubble.owner !== t) {
          hide();
          if (!t.dataset.tip) return;
          bubble = document.createElement('div');
          bubble.className = 'cubi-tip-bubble';
          bubble.textContent = t.dataset.tip;
          bubble.owner = t;
          document.body.appendChild(bubble);
          var r = t.getBoundingClientRect(), b = bubble.getBoundingClientRect();
          var top = r.bottom + 6 + b.height > innerHeight - 8 ? r.top - 6 - b.height : r.bottom + 6;
          bubble.style.left = Math.max(8, Math.min(r.left + r.width / 2 - b.width / 2, innerWidth - b.width - 8)) + 'px';
          bubble.style.top = Math.max(8, top) + 'px';
        }
        if (pin) bubble.pinned = true;
      }
      var tipOf = function (e) { return e.target.closest ? e.target.closest('.cubi-tip') : null; };
      document.addEventListener('mouseover', function (e) {
        var t = tipOf(e);
        if (t) show(t, false);
        else if (bubble && !bubble.pinned) hide();
      });
      document.addEventListener('click', function (e) {
        var t = tipOf(e);
        if (!t) { hide(); return; }
        e.preventDefault();   // a tip inside a <label> must not tick or focus its field
        if (bubble && bubble.owner === t && bubble.pinned) hide(); else show(t, true);
      }, true);
      document.addEventListener('scroll', hide, true);
    })();
    """

    /// Line icons, 24×24 strokes.
    static let icons = """
    {"dashboard":"<rect x='3' y='3' width='7' height='9' rx='1.5'/><rect x='14' y='3' width='7' height='5' rx='1.5'/><rect x='14' y='12' width='7' height='9' rx='1.5'/><rect x='3' y='16' width='7' height='5' rx='1.5'/>",
     "review":"<path d='M4 19V5a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v14l-4-2-4 2-4-2z'/><path d='M8 8h8M8 12h5'/>",
     "settings":"<circle cx='12' cy='12' r='3'/><path d='M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z'/>",
     "play":"<polygon points='7 4 20 12 7 20 7 4'/>",
     "pause":"<rect x='6' y='4' width='4' height='16' rx='1'/><rect x='14' y='4' width='4' height='16' rx='1'/>",
     "plus":"<path d='M12 5v14M5 12h14'/>",
     "minus":"<path d='M5 12h14'/>",
     "clock":"<circle cx='12' cy='12' r='9'/><path d='M12 7v5l3 2'/>",
     "refresh":"<path d='M21 12a9 9 0 1 1-2.6-6.4'/><path d='M21 4v5h-5'/>",
     "external":"<path d='M14 4h6v6'/><path d='M10 14 20 4'/><path d='M19 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h5'/>",
     "x":"<path d='M6 6l12 12M18 6 6 18'/>",
     "check":"<path d='M5 12l5 5L20 7'/>",
     "flag":"<path d='M5 21V4h11l-2 4 2 4H5'/>",
     "target":"<circle cx='12' cy='12' r='9'/><circle cx='12' cy='12' r='5'/><circle cx='12' cy='12' r='1'/>",
     "hourglass":"<path d='M6 3h12M6 21h12M7 3c0 5 10 5 10 9s-10 4-10 9M17 3c0 5-10 5-10 9s10 4 10 9'/>",
     "users":"<circle cx='9' cy='8' r='3.5'/><path d='M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6'/><path d='M16 4.5a3.5 3.5 0 0 1 0 7M21 20c0-2.6-1.6-4.9-4-5.7'/>",
     "sparkles":"<path d='M12 3l1.8 4.7L18.5 9.5l-4.7 1.8L12 16l-1.8-4.7L5.5 9.5l4.7-1.8z'/><path d='M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z'/>",
     "download":"<path d='M12 4v11M7 10l5 5 5-5'/><path d='M5 20h14'/>",
     "info":"<circle cx='12' cy='12' r='9'/><path d='M12 11v5M12 8h.01'/>",
     "link":"<path d='M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1'/><path d='M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1'/>"}
    """

    static let css = """
    :root { color-scheme: light dark;
      --cubi-bg: #f4f5f7; --cubi-card: #ffffff; --cubi-line: #e7e8ec; --cubi-line2: #f0f1f4;
      --cubi-ink: #111827; --cubi-ink2: #4b5563; --cubi-ink3: #9ca3af; --cubi-hover: #f3f4f6;
      --cubi-accent: #2563eb; --cubi-accent-soft: #e8efff; --cubi-on-accent: #ffffff;
      --cubi-good: #16a34a; --cubi-good-soft: #dcfce7; --cubi-warning: #d97706; --cubi-warning-soft: #fef3c7;
      --cubi-danger: #dc2626; --cubi-danger-soft: #fee2e2; --cubi-info: #2563eb; --cubi-info-soft: #e8efff;
      --cubi-neutral: #9ca3af; --cubi-neutral-soft: #f3f4f6;
      --cubi-c1: #2563eb; --cubi-c2: #16a34a; --cubi-c3: #f59e0b; --cubi-c4: #ef4444; --cubi-c5: #9ca3af;
      --cubi-radius: 14px; --cubi-shadow: 0 1px 2px rgba(17, 24, 39, .04); }
    @media (prefers-color-scheme: dark) { :root {
      --cubi-bg: #0f1115; --cubi-card: #181b21; --cubi-line: #262a33; --cubi-line2: #1f232b;
      --cubi-ink: #e5e7eb; --cubi-ink2: #b4bac5; --cubi-ink3: #7d8592; --cubi-hover: #20242c;
      --cubi-accent: #3b82f6; --cubi-accent-soft: #1b2a45; --cubi-on-accent: #ffffff;
      --cubi-good: #34d399; --cubi-good-soft: #13312a; --cubi-warning: #fbbf24; --cubi-warning-soft: #352a12;
      --cubi-danger: #f87171; --cubi-danger-soft: #3a1c1f; --cubi-info: #60a5fa; --cubi-info-soft: #1b2a45;
      --cubi-neutral: #7d8592; --cubi-neutral-soft: #20242c;
      --cubi-c1: #3b82f6; --cubi-c2: #34d399; --cubi-c3: #fbbf24; --cubi-c4: #f87171; --cubi-c5: #6b7280;
      --cubi-shadow: none; } }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--cubi-bg); color: var(--cubi-ink); font: 13px/1.5 -apple-system, "PingFang TC", "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; }
    a { color: var(--cubi-accent); text-decoration: none; } a:hover { text-decoration: underline; }
    input, select, textarea { font: inherit; color: var(--cubi-ink); background: var(--cubi-card); border: 1px solid var(--cubi-line); border-radius: 9px; padding: 6px 10px; }
    input:focus, select:focus, textarea:focus { outline: none; border-color: var(--cubi-accent); box-shadow: 0 0 0 3px var(--cubi-accent-soft); }
    textarea { width: 100%; resize: vertical; line-height: 1.55; }
    .cubi-icon { flex: none; vertical-align: -3px; }
    svg { max-width: 100%; }

    .cubi-app { display: grid; grid-template-columns: 196px 1fr; min-height: 100vh; }
    .cubi-nav { border-right: 1px solid var(--cubi-line); padding: 18px 12px; display: flex; flex-direction: column; gap: 2px; background: var(--cubi-card); }
    .cubi-brand { display: flex; align-items: center; gap: 8px; font-weight: 700; font-size: 15px; padding: 2px 10px 16px; }
    .cubi-nav-item { display: flex; align-items: center; gap: 10px; padding: 8px 10px; border-radius: 10px; color: var(--cubi-ink2); cursor: pointer; border: 0; background: none; font: inherit; text-align: left; width: 100%; }
    .cubi-nav-item:hover { background: var(--cubi-hover); }
    .cubi-nav-item.on { background: var(--cubi-accent-soft); color: var(--cubi-accent); font-weight: 600; }
    .cubi-nav-foot { margin-top: auto; }
    .cubi-main { padding: 20px 24px 32px; min-width: 0; }
    .cubi-header { display: flex; align-items: center; gap: 10px; margin-bottom: 18px; flex-wrap: wrap; }
    .cubi-title { font-size: 22px; font-weight: 700; letter-spacing: -.01em; margin: 0; }
    .cubi-spacer { flex: 1; }

    .cubi-btn { display: inline-flex; align-items: center; gap: 6px; font: inherit; font-weight: 500; color: var(--cubi-ink); background: var(--cubi-card); border: 1px solid var(--cubi-line); border-radius: 10px; padding: 6px 12px; cursor: pointer; white-space: nowrap; }
    .cubi-btn:hover { background: var(--cubi-hover); }
    .cubi-btn.primary { background: var(--cubi-accent); border-color: var(--cubi-accent); color: var(--cubi-on-accent); }
    .cubi-btn.primary:hover { filter: brightness(1.07); }
    .cubi-btn.danger { color: var(--cubi-danger); }
    .cubi-btn.icon { padding: 5px; border-radius: 8px; }
    .cubi-btn.small { padding: 3px 9px; font-size: 12px; }
    .cubi-btn:disabled { opacity: .5; cursor: default; }

    .cubi-kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 14px; margin-bottom: 16px; }
    .cubi-kpi, .cubi-card { background: var(--cubi-card); border: 1px solid var(--cubi-line); border-radius: var(--cubi-radius); box-shadow: var(--cubi-shadow); }
    .cubi-kpi { padding: 14px 16px; }
    .cubi-kpi-head { display: flex; align-items: center; justify-content: space-between; color: var(--cubi-ink2); font-weight: 600; font-size: 12.5px; }
    .cubi-kpi-head .cubi-icon { color: var(--cubi-accent); }
    .cubi-kpi-value { display: flex; align-items: baseline; gap: 8px; margin-top: 8px; }
    .cubi-kpi-value b { font-size: 26px; font-weight: 700; letter-spacing: -.02em; font-variant-numeric: tabular-nums; }
    .cubi-kpi-sub { color: var(--cubi-ink3); font-size: 11.5px; margin-top: 2px; }
    .cubi-delta { display: inline-flex; align-items: center; gap: 2px; font-size: 11.5px; font-weight: 600; padding: 1px 7px; border-radius: 999px; }
    .cubi-delta.up { color: var(--cubi-good); background: var(--cubi-good-soft); }
    .cubi-delta.down { color: var(--cubi-danger); background: var(--cubi-danger-soft); }
    .cubi-delta.flat { color: var(--cubi-ink3); background: var(--cubi-neutral-soft); }

    .cubi-card { padding: 16px 18px; margin-bottom: 16px; min-width: 0; }
    .cubi-card-head { display: flex; align-items: center; gap: 8px; margin-bottom: 12px; }
    .cubi-card-title { font-size: 14.5px; font-weight: 650; margin: 0; }
    .cubi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px; }
    .cubi-grid > .cubi-card { margin-bottom: 0; }
    .cubi-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .cubi-muted { color: var(--cubi-ink3); font-size: 12px; }
    .cubi-tip { color: var(--cubi-ink3); cursor: help; display: inline-flex; }
    .cubi-tip:hover { color: var(--cubi-accent); }
    .cubi-tip-bubble { position: fixed; z-index: 1000; max-width: 280px; padding: 7px 10px; border-radius: 8px; pointer-events: none;
      background: var(--cubi-ink); color: var(--cubi-card); font-size: 12px; font-weight: 400; line-height: 1.45; white-space: pre-line;
      text-transform: none; letter-spacing: 0; box-shadow: 0 6px 18px rgba(0, 0, 0, .18); }

    .cubi-table { width: 100%; border-collapse: collapse; }
    .cubi-table th { text-align: left; font-size: 11px; font-weight: 600; color: var(--cubi-ink3); text-transform: uppercase; letter-spacing: .05em; padding: 8px 10px; border-bottom: 1px solid var(--cubi-line); white-space: nowrap; }
    .cubi-table td { padding: 10px; border-bottom: 1px dashed var(--cubi-line2); vertical-align: middle; }
    .cubi-table tr:last-child td { border-bottom: 0; }
    .cubi-table tbody tr:hover td { background: var(--cubi-hover); }
    .cubi-table .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
    .cubi-table .clip { max-width: 320px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

    .cubi-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: var(--cubi-neutral); flex: none; }
    .cubi-dot.good { background: var(--cubi-good); } .cubi-dot.warning { background: var(--cubi-warning); }
    .cubi-dot.danger { background: var(--cubi-danger); } .cubi-dot.info { background: var(--cubi-info); }
    .cubi-pill { display: inline-flex; align-items: center; gap: 5px; font-size: 11.5px; font-weight: 600; padding: 2px 9px; border-radius: 999px; background: var(--cubi-neutral-soft); color: var(--cubi-ink2); white-space: nowrap; }
    .cubi-pill.good { background: var(--cubi-good-soft); color: var(--cubi-good); } .cubi-pill.warning { background: var(--cubi-warning-soft); color: var(--cubi-warning); }
    .cubi-pill.danger { background: var(--cubi-danger-soft); color: var(--cubi-danger); } .cubi-pill.info { background: var(--cubi-info-soft); color: var(--cubi-info); }
    .cubi-bar { height: 6px; border-radius: 999px; background: var(--cubi-line2); overflow: hidden; min-width: 60px; }
    .cubi-bar > i { display: block; height: 100%; border-radius: 999px; background: var(--cubi-accent); }
    .cubi-bar.good > i { background: var(--cubi-good); } .cubi-bar.warning > i { background: var(--cubi-warning); } .cubi-bar.danger > i { background: var(--cubi-danger); }

    .cubi-split { display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; gap: 10px; }
    .cubi-split > button { border: 0; background: none; text-align: left; padding: 6px 2px 10px; cursor: pointer; font: inherit; color: var(--cubi-ink); border-bottom: 4px solid var(--cubi-c5); border-radius: 0; }
    .cubi-split > button b { display: block; font-size: 20px; font-variant-numeric: tabular-nums; }
    .cubi-split > button span { color: var(--cubi-ink3); font-size: 11.5px; }
    .cubi-split > button.on { background: var(--cubi-hover); border-radius: 8px 8px 0 0; }

    .cubi-field label { display: flex; align-items: center; gap: 4px; font-size: 11.5px; font-weight: 600; color: var(--cubi-ink2); margin-bottom: 5px; }
    .cubi-field input, .cubi-field select { width: 100%; }
    .cubi-form { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px 16px; }
    .cubi-section-title { font-size: 11px; font-weight: 700; color: var(--cubi-ink3); text-transform: uppercase; letter-spacing: .07em; margin: 18px 0 10px; }
    .cubi-section-title:first-child { margin-top: 0; }
    .cubi-inline { background: var(--cubi-bg); border: 1px solid var(--cubi-line); border-radius: 10px; padding: 10px 12px; }
    .cubi-status { position: fixed; right: 18px; bottom: 16px; max-width: 60%; padding: 8px 14px; border-radius: 10px; background: var(--cubi-ink); color: var(--cubi-card); font-size: 12px; box-shadow: 0 4px 16px rgba(0,0,0,.18); }
    .cubi-status.err { background: var(--cubi-danger); color: #fff; }
    .cubi-status:empty { display: none; }
    """

    /// `text` as a JavaScript string literal (JSON escaping: quotes, backslashes, newlines).
    /// An array of one string always serializes; a failure here is a programming error.
    private static func jsString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
