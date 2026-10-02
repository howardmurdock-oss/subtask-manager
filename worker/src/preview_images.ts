/**
 * The link-preview and forum PNGs, drawn ahead of time by
 * tool/render_preview_images_test.dart (run it again if the design changes).
 *
 * Ready-made images rather than drawn per request: the time left goes in the
 * preview's title, and forums that take SVG still get the live-time badge.
 * Bundled as raw bytes - about 85 KB for all six.
 */
import previewLocked from './images/preview-locked.png';
import previewUnlocked from './images/preview-unlocked.png';
import previewEnded from './images/preview-ended.png';
import badgeLocked from './images/badge-locked.png';
import badgeUnlocked from './images/badge-unlocked.png';
import badgeEnded from './images/badge-ended.png';

export type PreviewState = 'locked' | 'unlocked' | 'ended';

const PREVIEW: Record<PreviewState, ArrayBuffer> = {
  locked: previewLocked,
  unlocked: previewUnlocked,
  ended: previewEnded,
};
const BADGE: Record<PreviewState, ArrayBuffer> = {
  locked: badgeLocked,
  unlocked: badgeUnlocked,
  ended: badgeEnded,
};

export function pngResponse(kind: 'preview' | 'badge', state: PreviewState): Response {
  return new Response(kind === 'preview' ? PREVIEW[state] : BADGE[state], {
    headers: {
      'content-type': 'image/png',
      // A minute: link previews and forum posts that go wide stay cheap,
      // and a change of state shows soon after.
      'cache-control': 'public, max-age=60',
      'x-robots-tag': 'noindex, nofollow',
      'access-control-allow-origin': '*',
    },
  });
}
