// Pure helpers for "audio sync": relating a recording's playback position to
// the ink drawn at that moment. A recording stores its wall-clock startedAt;
// every StrokeElement already carries a wall-clock createdAt, so no per-stroke
// schema change is needed — the playhead maps to a wall-clock and selects the
// strokes drawn around it.

/// The wall-clock instant currently under the playhead.
DateTime playheadWallclock(DateTime startedAt, Duration position) =>
    startedAt.add(position);

/// Default glow window: a stroke lights up for this long after it was drawn,
/// relative to the playhead.
const Duration kAudioGlowWindow = Duration(milliseconds: 1600);

/// Whether a stroke drawn at [strokeCreatedAt] should be highlighted when the
/// playhead is at [playhead] — i.e. it was drawn at or before the playhead and
/// within [window] of it. Strokes drawn after the playhead (later in the take)
/// don't glow yet.
bool strokeActiveAt(
  DateTime strokeCreatedAt,
  DateTime playhead, {
  Duration window = kAudioGlowWindow,
}) {
  if (strokeCreatedAt.isAfter(playhead)) return false;
  return playhead.difference(strokeCreatedAt) <= window;
}
