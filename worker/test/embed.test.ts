// Run with: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { badgeSvg, embedPage, endedEmbedPage } from '../src/embed.ts';

const now = Date.UTC(2026, 9, 2, 12);

test('the image shows the time left on a running timer', () => {
  const svg = badgeSvg({ status: 'running', endAt: now + (2 * 24 + 4) * 3600e3, acceptingVotes: true, now });
  assert.match(svg, /Locked · 2d 4h left/);
  assert.match(svg, /Click to vote/);
  assert.match(svg, /^<svg xmlns/);
});

test('the image keeps a hidden time hidden', () => {
  const svg = badgeSvg({ status: 'running', endAt: null, acceptingVotes: true, now });
  assert.match(svg, /time hidden/);
});

test('the image says when a timer is over, and when it has gone', () => {
  assert.match(badgeSvg({ status: 'ended', endAt: now, acceptingVotes: false, now }), /Unlocked/);
  const gone = badgeSvg(null);
  assert.match(gone, /Timer ended/);
  assert.match(gone, /Get \(sub\)Task Manager/);
});

test('the widget links its Vote button to the full page, in a new tab', () => {
  const page = embedPage('https://subtaskmanager.com/t/abc123XYZ');
  assert.match(page, /href="https:\/\/subtaskmanager\.com\/t\/abc123XYZ" target="_blank"/);
  assert.match(page, /noindex/);
});

test('the ended widget points to the app', () => {
  const page = endedEmbedPage();
  assert.match(page, /Timer ended/);
  assert.match(page, /www\.subtaskmanager\.com\/\?from=timer-embed/);
});

test('a link preview puts the time left in its title', async () => {
  const { previewText } = await import('../src/embed.ts');
  const running = previewText({ status: 'running', endAt: now + 26 * 3600e3, acceptingVotes: true, allowRemove: true, now });
  assert.equal(running.title, 'Chastity Timer · 1d 2h left');
  assert.equal(running.description, 'Someone is locked up. Vote to add or remove time.');
  assert.equal(previewText({ status: 'running', endAt: null, acceptingVotes: true, now }).title, 'Chastity Timer · time hidden');
  assert.equal(previewText({ status: 'released', endAt: now, acceptingVotes: false, now }).title, 'Chastity Timer · Unlocked');
});

test('the timer page and the ended page carry link-preview tags', async () => {
  const { publicPage, expiredPage } = await import('../src/public_page.ts');
  const page = publicPage('abc123XYZ', null, { title: 'Chastity Timer · 2d 4h left', description: 'Vote.', state: 'locked' });
  assert.match(page, /<meta property="og:title" content="Chastity Timer · 2d 4h left">/);
  assert.match(page, /<meta property="og:image" content="https:\/\/subtaskmanager\.com\/t\/abc123XYZ\/preview\.png">/);
  assert.match(page, /twitter:card" content="summary_large_image"/);
  const ended = expiredPage();
  assert.match(ended, /og:title" content="Chastity Timer · Timer ended"/);
  assert.match(ended, /t\/timer-ended\/preview\.png/);
});

test('an open-ended timer is shown as time so far, with nothing to vote on', async () => {
  const { previewText } = await import('../src/embed.ts');
  const start = now - (3 * 24 + 4) * 3600e3;
  const v = { status: 'running' as const, endAt: null, startAt: start, openEnded: true, acceptingVotes: false, now };
  assert.equal(previewText(v).title, 'Chastity Timer · locked 3d 4h so far');
  const svg = badgeSvg(v);
  assert.match(svg, /Locked · 3d 4h so far/);
  assert.match(svg, /No end time/);
});

test('a finished timer says how long it ran', async () => {
  const { previewText } = await import('../src/embed.ts');
  const v = { status: 'released' as const, endAt: null, startAt: now - 50 * 3600e3, closedAt: now - 2 * 3600e3, acceptingVotes: false, now };
  assert.match(badgeSvg(v), /Ran for 2d 0h/);
  assert.equal(previewText(v).description, 'This timer is over. It ran for 2d 0h.');
});
