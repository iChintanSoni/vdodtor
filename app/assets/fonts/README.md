# Bundled typefaces

The five faces a caption can be set in, and the only ones vdodtor ships. They
are **bundled rather than taken from the machine** so that a project made on one
computer opens looking the same on another — the alternative is a title that
silently reflows when a file crosses a desk.

Each one does a job the others cannot, which is the whole reason the list is
five and not fifty:

| Family | File | Job |
| --- | --- | --- |
| Inter | `Inter.ttf` | The workhorse sans, and the default. Reads at any size, and carries Latin, Greek and Cyrillic — captions are not all in English. |
| Anton | `Anton.ttf` | Heavy condensed poster face, for the big line across the middle of the frame. |
| Playfair Display | `PlayfairDisplay.ttf` | High-contrast serif, for anything that wants to look considered. |
| Caveat | `Caveat.ttf` | Handwriting, for an annotation that should not look typeset. |
| Space Mono | `SpaceMono.ttf` | Monospace, for code, timecodes and the technical look. |

All five are licensed under the **SIL Open Font Licence 1.1**, whose terms allow
redistribution inside an application. The licence for each ships beside it as
`OFL-<Family>.txt` and must stay there: the OFL requires the copyright notice
and licence to travel with the font. A face whose licence does not allow
bundling has no business in a product sold without an account.

## Provenance

Taken from [google/fonts](https://github.com/google/fonts) on 2026-08-31, and
renamed to the family name — the brackets in a variable font's own filename
(`Inter[opsz,wght].ttf`) are awkward in an asset path, and nothing reads the
filename anyway. The family name comes from inside the file.

| File here | Path in google/fonts |
| --- | --- |
| `Inter.ttf` | `ofl/inter/Inter[opsz,wght].ttf` |
| `Anton.ttf` | `ofl/anton/Anton-Regular.ttf` |
| `PlayfairDisplay.ttf` | `ofl/playfairdisplay/PlayfairDisplay[wght].ttf` |
| `Caveat.ttf` | `ofl/caveat/Caveat[wght].ttf` |
| `SpaceMono.ttf` | `ofl/spacemono/SpaceMono-Regular.ttf` |

Four of the five are variable fonts, and the engine draws each at its **default
instance** — the regular weight. There is no weight control yet; when one
arrives it will set the `wght` axis rather than add more files.

## Adding one

1. Put the file and its `OFL-<Family>.txt` here.
2. Add it to `BundledFonts.assets` in `app/lib/media/fonts.dart`, in the order
   the picker should offer it.
3. Add it to **both** the `assets:` and `fonts:` sections of `app/pubspec.yaml`
   — Flutter needs the second to preview the face in the inspector, and the app
   needs the first to read the bytes and hand them to the engine.

`app/test/media/fonts_test.dart` fails if these disagree with what is actually
in this directory, which is the only thing stopping a face from being shipped
and never offered, or offered and never shipped.
