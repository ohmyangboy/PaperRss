# Article preview images and timeline views

- **Status**: accepted
- **Issues**: https://github.com/ohmyangboy/PaperRss/issues/32, https://github.com/ohmyangboy/PaperRss/issues/18
- **Baseline**: main at 012eb1c34057427cd86cf693ea83f88deed97ff2

## Scope and acceptance

The macOS toolbar has a permanent upper-right view button. Its popover contains
three horizontally arranged icon choices: list, magazine, cards. Existing list
navigation, chronological order, unread-session retention, reader actions,
sidebar, theme and account behavior are preserved. Visual modes use the same
paged timeline and can expand into the reader area; opening an article restores
the reader, and a return-to-browse action restores the visual timeline.

Preview selection uses explicit item images, then the first usable image from
raw description/summary HTML, then content HTML. Local RSS/Atom/JSON Feed and
FreshRSS share selection rules. Metadata is persisted and included in both
list and neighbor projections without loading full HTML into timeline items.
Existing visible pages are backfilled in bounded batches, off the main thread.
No webpage, Open Graph lookup, proxy, new dependency or fabricated cover is used.

Image bytes use an account-isolated, bounded, cancellable memory/disk cache,
with off-main-thread ImageIO downsampling and finite failure caching. URLs are
limited to HTTP(S), with no provider credentials, cookies or referrer forwarded.
Choosing a visual view explicitly enables its on-demand images in automatic
mode. The default list retains its former no-image behavior until the user
enables images. An explicit off preference applies to every view.

## Data and delivery boundaries

Additive migration only; no change to read/star state or item identity. No real
user library is opened during implementation. Publish a feature branch, never
merge main or publish a release. Existing description HTML that older versions
already discarded cannot be reconstructed; it can be recovered only when the
source returns that item again.

## Verification

Run core, feature and reader/web regression plus unsigned macOS host build.
Exercise extraction edge cases, metadata insert/update/restoration, bounded
backfill, account isolation, cache cancellation, failure handling and preferences.
Actual macOS interaction remains **Manual UI verification required** until a
maintainer checks split widths, focus, keyboard shortcuts, scroll restoration,
all three layouts, image-off behavior, dark/light themes and long mixed feeds.
