/**
 * Counting downloads from the website.
 *
 * The site's download buttons point at subtaskmanager.com/download/<platform>,
 * which counts the click and sends the browser on to the same GitHub release
 * file as before. The in-app updater still links straight to GitHub, so these
 * counts are people getting the app from the site, not copies updating.
 *
 * Only a count per day and platform is kept: no address, no cookie, nothing
 * about who clicked.
 */

const RELEASES = 'https://github.com/howardmurdock-oss/subtask-manager/releases/latest/download';

/** What each /download/<platform> sends the browser to. */
export const DOWNLOADS: Record<string, { file: string; label: string }> = {
  windows: { file: 'subTaskManager-Windows-Release.zip', label: 'Windows' },
  android: { file: 'subTaskManager-Android-Release.apk', label: 'Android' },
  macos: { file: 'SubTaskManager-macOS.dmg', label: 'macOS' },
  linux: { file: 'SubTaskManager-Linux-x64.tar.gz', label: 'Linux (.tar.gz)' },
  appimage: { file: 'SubTaskManager-Linux-x86_64.AppImage', label: 'Linux (AppImage)' },
};

export const releaseUrl = (platform: string) => `${RELEASES}/${DOWNLOADS[platform].file}`;

/**
 * Link previews and crawlers, which fetch a link without anyone downloading
 * anything. Pasting a download link into Discord or Slack would otherwise
 * count as a download each time it was shown.
 */
export function isBot(userAgent: string | null): boolean {
  if (!userAgent) return true;
  return /bot|crawl|spider|slurp|preview|facebookexternalhit|embedly|discord|telegram|whatsapp|skype|slack|twitter|linkedin|headless/i
    .test(userAgent);
}

export interface CountRow {
  day: string;
  platform: string;
  count: number;
}

export interface Summary {
  total: number;
  last7: number;
  last30: number;
  byPlatform: { platform: string; label: string; total: number; last30: number }[];
  /** Newest first, one entry per day that had any downloads, last 30 days. */
  byDay: { day: string; total: number; counts: Record<string, number> }[];
}

const dayBefore = (today: string, days: number) => {
  const d = new Date(`${today}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().slice(0, 10);
};

export function summarize(rows: CountRow[], today: string): Summary {
  const since7 = dayBefore(today, 6);
  const since30 = dayBefore(today, 29);
  const byPlatform = Object.entries(DOWNLOADS).map(([platform, { label }]) => {
    const mine = rows.filter((r) => r.platform === platform);
    return {
      platform,
      label,
      total: mine.reduce((s, r) => s + r.count, 0),
      last30: mine.filter((r) => r.day >= since30).reduce((s, r) => s + r.count, 0),
    };
  });
  const days = new Map<string, Record<string, number>>();
  for (const r of rows.filter((r) => r.day >= since30)) {
    const counts = days.get(r.day) ?? {};
    counts[r.platform] = (counts[r.platform] ?? 0) + r.count;
    days.set(r.day, counts);
  }
  return {
    total: rows.reduce((s, r) => s + r.count, 0),
    last7: rows.filter((r) => r.day >= since7).reduce((s, r) => s + r.count, 0),
    last30: rows.filter((r) => r.day >= since30).reduce((s, r) => s + r.count, 0),
    byPlatform,
    byDay: [...days.entries()]
      .sort(([a], [b]) => b.localeCompare(a))
      .map(([day, counts]) => ({ day, counts, total: Object.values(counts).reduce((s, n) => s + n, 0) })),
  };
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export function statsPage(summary: Summary, today: string): string {
  const platforms = Object.keys(DOWNLOADS);
  const maxDay = Math.max(1, ...summary.byDay.map((d) => d.total));
  const maxPlatform = Math.max(1, ...summary.byPlatform.map((p) => p.total));
  const tile = (label: string, value: number) =>
    `<div class="tile"><div class="n">${value}</div><div class="l">${esc(label)}</div></div>`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Downloads</title>
<style>
  :root { --bg:#0e0f14; --card:#171922; --line:#262a36; --text:#eef0f6; --muted:#9aa0b4; --accent:#22d3ee; }
  @media (prefers-color-scheme: light) { :root { --bg:#f5f6fa; --card:#fff; --line:#e3e5ee; --text:#161823; --muted:#5d6275; } }
  * { box-sizing: border-box; }
  body { margin:0; padding:16px; background:var(--bg); color:var(--text); font:15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { max-width:760px; margin:0 auto; }
  h1 { font-size:20px; margin:8px 0 4px; }
  .sub { color:var(--muted); font-size:13px; margin-bottom:16px; }
  .tiles { display:grid; grid-template-columns:repeat(3, 1fr); gap:10px; margin-bottom:16px; }
  .tile, .card { background:var(--card); border:1px solid var(--line); border-radius:14px; }
  .tile { padding:14px; }
  .n { font-size:28px; font-weight:800; font-variant-numeric:tabular-nums; }
  .l { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.08em; }
  .card { padding:14px 16px; margin-bottom:16px; overflow-x:auto; }
  h2 { font-size:12px; letter-spacing:.12em; text-transform:uppercase; color:var(--accent); margin:0 0 10px; }
  table { width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }
  th, td { text-align:right; padding:6px 8px; border-bottom:1px solid var(--line); white-space:nowrap; }
  th:first-child, td:first-child { text-align:left; }
  th { color:var(--muted); font-weight:600; font-size:12px; }
  .bar { height:8px; border-radius:4px; background:var(--accent); opacity:.8; }
  .barcell { width:40%; }
  .empty { color:var(--muted); }
</style>
</head>
<body>
<main>
  <h1>Website downloads</h1>
  <div class="sub">Clicks on the site's download buttons, by day (UTC). Updates from inside the app are not counted. Today: ${esc(today)}.</div>
  <div class="tiles">${tile('Last 7 days', summary.last7)}${tile('Last 30 days', summary.last30)}${tile('All time', summary.total)}</div>

  <div class="card">
    <h2>By platform</h2>
    <table>
      <tr><th>Platform</th><th>30 days</th><th>All time</th><th class="barcell"></th></tr>
      ${summary.byPlatform.map((p) => `<tr><td>${esc(p.label)}</td><td>${p.last30}</td><td>${p.total}</td>
        <td class="barcell"><div class="bar" style="width:${(p.total / maxPlatform) * 100}%"></div></td></tr>`).join('')}
    </table>
  </div>

  <div class="card">
    <h2>Last 30 days</h2>
    ${summary.byDay.length === 0 ? '<div class="empty">No downloads yet.</div>' : `<table>
      <tr><th>Day</th>${platforms.map((p) => `<th>${esc(DOWNLOADS[p].label)}</th>`).join('')}<th>Total</th><th class="barcell"></th></tr>
      ${summary.byDay.map((d) => `<tr><td>${esc(d.day)}</td>${platforms.map((p) => `<td>${d.counts[p] ?? ''}</td>`).join('')}
        <td><b>${d.total}</b></td><td class="barcell"><div class="bar" style="width:${(d.total / maxDay) * 100}%"></div></td></tr>`).join('')}
    </table>`}
  </div>
</main>
</body>
</html>`;
}

/** Whether the request carries the stats password (HTTP Basic, any user name). */
export async function hasStatsPassword(authorization: string | null, password: string | undefined): Promise<boolean> {
  if (!password || !authorization?.startsWith('Basic ')) return false;
  let given = '';
  try {
    const decoded = atob(authorization.slice(6));
    given = decoded.slice(decoded.indexOf(':') + 1);
  } catch {
    return false;
  }
  // Compared as digests, so the time taken says nothing about how much of
  // the password matched.
  const digest = async (s: string) =>
    new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  const [a, b] = await Promise.all([digest(given), digest(password)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}
