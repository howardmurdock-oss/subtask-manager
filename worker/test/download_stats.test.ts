// Run with: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DOWNLOADS, hasStatsPassword, isBot, releaseUrl, statsPage, summarize } from '../src/download_stats.ts';

test('every platform goes to its GitHub release file', () => {
  assert.equal(
    releaseUrl('windows'),
    'https://github.com/howardmurdock-oss/subtask-manager/releases/latest/download/subTaskManager-Windows-Release.zip',
  );
  assert.deepEqual(Object.keys(DOWNLOADS).sort(), ['android', 'appimage', 'linux', 'macos', 'windows']);
});

test('link previews and crawlers are not counted; browsers are', () => {
  for (const ua of [
    'Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)',
    'Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)',
    'facebookexternalhit/1.1',
    'TelegramBot (like TwitterBot)',
    'Mozilla/5.0 (compatible; Googlebot/2.1)',
    null,
  ]) {
    assert.equal(isBot(ua), true, String(ua));
  }
  assert.equal(isBot('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36'), false);
  assert.equal(isBot('Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 Chrome/130.0 Mobile Safari/537.36'), false);
});

test('counts are totalled by platform, and over 7 and 30 days', () => {
  const s = summarize(
    [
      { day: '2026-09-29', platform: 'windows', count: 3 },
      { day: '2026-09-29', platform: 'android', count: 2 },
      { day: '2026-09-25', platform: 'android', count: 1 },
      { day: '2026-09-10', platform: 'macos', count: 4 },
      { day: '2026-07-01', platform: 'windows', count: 10 },
    ],
    '2026-09-29',
  );
  assert.equal(s.total, 20);
  assert.equal(s.last7, 6);
  assert.equal(s.last30, 10);
  assert.equal(s.byPlatform.find((p) => p.platform === 'windows')!.total, 13);
  assert.equal(s.byPlatform.find((p) => p.platform === 'windows')!.last30, 3);
  assert.deepEqual(s.byDay.map((d) => d.day), ['2026-09-29', '2026-09-25', '2026-09-10'], 'newest first, last 30 days only');
  assert.equal(s.byDay[0].total, 5);
});

test('the page renders with and without data', () => {
  assert.match(statsPage(summarize([], '2026-09-29'), '2026-09-29'), /No downloads yet/);
  const page = statsPage(summarize([{ day: '2026-09-29', platform: 'android', count: 7 }], '2026-09-29'), '2026-09-29');
  assert.match(page, /noindex/);
  assert.match(page, /Android/);
});

test('the stats password is checked, whatever user name is given', async () => {
  const basic = (user: string, pass: string) => `Basic ${btoa(`${user}:${pass}`)}`;
  assert.equal(await hasStatsPassword(basic('me', 'right-password'), 'right-password'), true);
  assert.equal(await hasStatsPassword(basic('', 'right-password'), 'right-password'), true);
  assert.equal(await hasStatsPassword(basic('me', 'wrong'), 'right-password'), false);
  assert.equal(await hasStatsPassword(null, 'right-password'), false);
  assert.equal(await hasStatsPassword(basic('me', 'anything'), undefined), false, 'no password set: nobody gets in');
  assert.equal(await hasStatsPassword('Basic !!!not-base64', 'right-password'), false);
});
