import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  cleanBio,
  cleanMessageText,
  cleanSenderName,
  cleanSocials,
  cleanVisitorId,
} from '../src/profile.ts';
import { sanitizePublicOrders } from '../src/public_orders.ts';

test('cleanBio sanitizes control characters, trims, and enforces max length', () => {
  assert.equal(cleanBio(null), null);
  assert.equal(cleanBio('   '), null);
  assert.equal(cleanBio('  Hello \u0000world!\u001f  '), 'Hello  world!');
  const longBio = 'a'.repeat(300);
  assert.equal(cleanBio(longBio)!.length, 250);
});

test('cleanSocials validates URLs, supported platforms, and bounds items', () => {
  assert.deepEqual(cleanSocials(null), []);
  assert.deepEqual(cleanSocials('not-an-array'), []);
  
  const raw = [
    { platform: 'reddit', label: ' u/MyUser ', url: 'https://reddit.com/u/MyUser' },
    { platform: 'DISCORD', label: 'Discord Server', url: 'https://discord.gg/invite' },
    { platform: 'onlyfans', label: 'OnlyFans', url: 'https://onlyfans.com/creator' },
    { platform: 'fansly', label: 'Fansly', url: 'https://fansly.com/creator' },
    { platform: 'invalid_proto', label: 'Bad Link', url: 'javascript:alert(1)' },
    { platform: 'unknown', label: 'Personal Site', url: 'https://example.com' },
  ];

  const cleaned = cleanSocials(raw);
  assert.equal(cleaned.length, 5, 'javascript protocol dropped');
  assert.equal(cleaned[0].platform, 'reddit');
  assert.equal(cleaned[0].label, 'u/MyUser');
  assert.equal(cleaned[1].platform, 'discord');
  assert.equal(cleaned[4].platform, 'custom');
  assert.equal(cleaned[4].label, 'Personal Site');
});

test('cleanMessageText and cleanSenderName sanitize visitor message fields', () => {
  assert.equal(cleanMessageText(''), null);
  assert.equal(cleanMessageText('   '), null);
  assert.equal(cleanMessageText('  Hello! Hope you are doing well.  '), 'Hello! Hope you are doing well.');
  assert.equal(cleanSenderName(''), null);
  assert.equal(cleanSenderName('  Anon Keyholder  '), 'Anon Keyholder');
  const longName = 'x'.repeat(100);
  assert.equal(cleanSenderName(longName)!.length, 40);
  const longMsg = 'm'.repeat(800);
  assert.equal(cleanMessageText(longMsg)!.length, 500);
});

test('cleanVisitorId sanitizes and truncates visitor identifiers', () => {
  assert.equal(cleanVisitorId(null), '');
  assert.equal(cleanVisitorId(undefined), '');
  assert.equal(cleanVisitorId(''), '');
  assert.equal(cleanVisitorId('visitor_123-abc'), 'visitor_123-abc');
  assert.equal(cleanVisitorId('bad/chars!@#$'), 'badchars');
  const longId = 'v'.repeat(100);
  assert.equal(cleanVisitorId(longId).length, 64);
});
