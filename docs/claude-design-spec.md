# DRY Eyes — brief for Claude Design

Two assets, matching the visual family already established by the sibling
project [16 Eyes](https://github.com/kigiela/16-eyes) (same author, same
"eyes" naming convention, same brand color `#0F6E56`) — paste each section
below into Claude Design (claude.ai/design) as its own request.

## Shared visual language

- **Brand color:** `#0F6E56` (deep teal-green — matches 16 Eyes' badge
  color, used here for visual continuity across the two products as a
  recognizable "family").
- **Theme:** eyes/vision, continuing 16 Eyes' own visual identity, but with
  a **duplication/mirroring** twist specific to what DRY Eyes actually
  does — two (or more) near-identical eyes/lenses side by side, where a
  close look reveals they're subtly different from each other, not
  perfect copies. That's the entire concept in one image: things that look
  like duplicates rarely are, on close inspection.
- **Mood:** clean, technical, a little wry (DRY Eyes is a pun — "Don't
  Repeat Yourself" + "dry eyes" — the visual can wink at this without
  spelling out the joke literally).
- **Style:** flat/vector illustration, not photographic — matching a
  modern dev-tool aesthetic (think: the illustration style of tools like
  Linear, Raycast, or Vercel's marketing pages), dark background with the
  teal-green as the accent color, generous negative space (this needs to
  render legibly as a small GitHub README preview image too, not just
  full-size).

## Asset 1 — hero image (`assets/Background.png`)

A wide banner image (roughly 1200×400px, GitHub README hero proportions).

**Composition:** Two or three eye/lens shapes arranged in a row, styled
like magnifying glasses or camera apertures rather than literal anatomical
eyes (matching whatever abstraction level 16 Eyes' own eye motif used).
At a glance they look identical — same size, same position, same outer
shape. But each one's "iris" or interior contains a tiny fragment of code
(a few abstract lines suggesting syntax, not literally readable text), and
on close inspection those interior fragments are **not quite the same** —
one is slightly different in a way that's visible once you look (different
color accent inside one, or one shape's fragment is subtly rotated/offset,
or one has an extra small element the others lack). This is the whole
DRY Eyes thesis, rendered visually: they look like the same thing until you
actually compare them.

**Text on image:** just "DRY Eyes" as a wordmark, clean sans-serif,
positioned so it doesn't fight with the eye shapes (bottom-left or
top-left corner, similar to where 16 Eyes' own hero probably places its
wordmark — check `16-eyes/assets/Background.png` for the exact placement
convention to match).

**What to explicitly avoid:** don't make the "difference" between the eyes
so obvious it reads as a "spot the difference" puzzle graphic — it should
look like a clean, confident brand image first, with the duplication/twist
concept as something you notice on a second look, not the headline.

## Asset 2 — "how it works" diagram (`assets/how-it-works-en.png`, plus
`-pt-br.png` and `-es.png` with the same diagram, labels translated)

A horizontal flow diagram, same visual family as Asset 1 (dark background,
teal-green accents, flat vector style), showing DRY Eyes' actual pipeline
as a sequence of connected stages. Five stages, left to right, connected by
arrows:

1. **Signals** — icon suggesting cheap/fast automated detection (a magnifying
   glass or radar-sweep icon). Label: "5 cheap signals scan the repo" /
   pt-br: "5 sinais baratos varrem o repo" / es: "5 señales baratas escanean
   el repo".
2. **Candidates** — icon suggesting grouping/clustering (a few dots
   connecting into a cluster). Label: "candidates clustered" / pt-br:
   "candidatos agrupados" / es: "candidatos agrupados".
3. **Verify** — icon suggesting a checkmark or a skeptical/questioning
   symbol (a magnifying glass over a checkmark works well, echoing 16 Eyes'
   own "skeptical verifier" visual language if it used one). Label:
   "verified against the real code" / pt-br: "verificado contra o código
   real" / es: "verificado contra el código real".
4. **Compare** — the most important stage visually: **three small
   identical-looking figures (echoing the eye/lens motif from Asset 1),
   each pointing at a different one of several code variants, with at
   least one of the three pointing at "none of them" / a blank/question
   mark** rather than all three converging on the same answer. This is
   the single most important visual idea in the whole diagram — it should
   visually communicate "independent judges, and disagreement is normal,
   not a failure." Label: "independent comparison — 'none of them' is a
   valid answer" / pt-br: "comparação independente — 'nenhuma delas' é uma
   resposta válida" / es: "comparación independiente — 'ninguna de ellas'
   es una respuesta válida".
5. **Report** — icon suggesting a document/report (a simple page icon with
   a couple of lines, maybe with a small "?" or flag on one line to
   suggest "needs a decision"). Label: "report — leads with what needs a
   decision" / pt-br: "relatório — começa pelo que precisa de decisão" /
   es: "informe — empieza por lo que necesita una decisión".

**Text at the very top of the diagram** (title, above the 5 stages):
"How DRY Eyes works" / pt-br: "Como o DRY Eyes funciona" / es: "Cómo
funciona DRY Eyes" (this text is what the image's own alt-text/heading
should echo, matching the README's `![How DRY Eyes works](...)` alt text).

## After generating

Save the exported files into this repo at:

```
assets/Background.png
assets/how-it-works-en.png
assets/how-it-works-pt-br.png
assets/how-it-works-es.png
```

(paths already referenced by `README.md` / `README.pt-BR.md` / `README.es.md`
— they'll start rendering the moment the files land there, no other change
needed).
