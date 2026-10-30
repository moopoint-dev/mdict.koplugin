# mdict.koplugin

MDict (.mdx/.mdd) dictionaries for KOReader, shown in KOReader's own
dictionary popup next to its StarDict dictionaries. On Android, entries are
laid out by the system WebView (Chromium) and shown a page at a time, so
complex dictionary layouts keep their original look, including vertical
Japanese. Elsewhere, entries fall back to KOReader's built-in HTML renderer.

## Install

1. Unzip a release zip (`mdict.koplugin-<version>.zip`) into `koreader/plugins/`.
   The repository itself is not the plugin folder: from a checkout, copy its
   `mdict.koplugin/` folder instead.
2. Put dictionaries in KOReader's dictionary folder (`koreader/data/dict/`), or
   add folders under *Search → Settings → MDict dictionaries → Dictionary folders*.
   Keep each `.mdx` next to its `.mdd` files (`name.mdd`, `name.1.mdd`, ...).
3. Restart KOReader. MDict dictionaries appear in KOReader's *Manage dictionaries*
   list, where they are enabled, disabled and ordered like StarDict ones.

Large dictionaries whose keys are not in the plugin's sort order are indexed
once in the background (a few seconds each). Until then their lookups show a
note; a notification says when an index you were waiting for is ready.

## Reading entries

- Horizontal entries: swipe up/down or tap the right/left half to turn pages.
- Vertical (right-to-left) entries: swipe left to right, or tap the left half,
  for the next page; swipe up/down to change dictionary. The page bar runs
  along the bottom.
- Links, `#anchors` and cross references work; tapping a collapsed section
  (such as *Extra Examples*) opens it in place.
- Hold a word to look it up; hold and drag to select. *Find in definition*
  searches the whole entry.
- Tap a speaker icon to hear the recording (Android; AAC, MP3, Ogg and WAV
  play, Speex does not).

## Settings

*MDict dictionaries* in the search menu:

- **Display**: render with the WebView or KOReader's renderer, text size,
  e-ink mode (black text, no tinted backgrounds), your own font for all text,
  Latin text only, or Japanese/Chinese text only, and reversed swipes for
  vertical text.
- **Dictionary settings**: per dictionary, the writing direction (automatic,
  horizontal, vertical) and page layout (columns, or slices for layouts that
  columns cut off; automatic switches when needed).
- **Index status**, **Rebuild indexes**, **Clear extracted resources**, **Rescan**.

Override files, for fixes a dictionary's own CSS or markup needs on an e-reader:

- `name.koreader.css` next to `name.mdx`: extra CSS applied after the dictionary's own.
- `name.koreader.lua` next to `name.mdx`: returns a function that takes an entry's
  HTML and returns it changed, for fixes CSS cannot make. It can use the `string`,
  `table` and `math` libraries only.
- `mdict.koreader.css` and `mdict.koreader.lua` in a dictionary folder (or a folder
  inside it): the same, for every dictionary in that folder and below, for example
  all the files from one exporter. They apply before the per-dictionary files.

## Dictionary exporters

Files whose keys are sorted by the plugin's `kosort-1` order can be used
without an index. Exporters can say so with the header attribute
`KOReaderKeyOrder="kosort-1"`; the plugin still verifies the order once in
the background. `tools/kosort.py` is the reference implementation, with test
vectors in `spec/data/kosort-1.tsv`.

## Layout

- `mdict.koplugin/mdict/`: MDict reader (v1.2/v2, zlib/LZO, encrypted key index),
  the `kosort-1` key order and the sidecar index, lookups, KOReader hooks.
- `mdict.koplugin/renderers/`: the pager (pager.js/pager.css), the pager document,
  the WebView driver and its backends (Android JNI bridge, desktop Chromium bridge).
- `mdict.koplugin/widgets/`: the popup widgets (KOReader's HtmlBoxWidget and
  ScrollHtmlWidget interfaces, backed by the pager).
- `android/`: Java side of the Android bridge, built into
  `mdict.koplugin/android/mdict-bridge.dex` and loaded at runtime (no custom
  KOReader build needed).
- `tools/`: test fixture generator, inspection and index tools, the `kosort-1`
  reference implementation, Chromium harnesses, `release.sh`, and `emulator/`
  (an Android emulator shaped like a 7" 300 ppi e-reader, with KOReader; see its README).
- `spec/`: busted specs.

## Development

    busted --lua=luajit spec/         # unit tests
    luacheck mdict.koplugin tools spec
    # popup widgets and menus against a KOReader checkout, rendering with headless Chromium:
    KOREADER_FRONTEND=<koreader>/frontend MDICT_CHROMIUM_BRIDGE=$PWD/tools/chromium-bridge/bridge.js \
        NODE_PATH=<dir with playwright> busted spec/
    ANDROID_JAR=.../android-30.jar android/build.sh
    NODE_PATH=... node tools/pager-test/run.js --res <res dir> --out <dir> entry.html
    tools/release.sh [version]        # dist/mdict.koplugin-<version>.zip

Vertical Japanese test renders need a CJK font with vertical metrics (for
example `fonts-noto-cjk`); without one, Chromium overlaps the glyphs.

## License

AGPL-3.0, like KOReader. See `LICENSE`.
