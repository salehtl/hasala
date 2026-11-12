# Concise copy (2026-11-10; proposed, the owner confirms in review)

The app's copy explained too much. Many lines told the reason behind a step, said "on this
iPhone" or "read-only" again on the same screen, or put a privacy detail in every footer.
People read less of a long line, so the important part was easy to miss.

**Decision.** Each line says what happened or what to do, then stops.

- A subtitle, footer, caption or toast is one sentence, about 12 words or fewer.
- Body text and errors are at most two short sentences, about 25 words. An error says what
  happened, then what to do.
- No visible line is longer than 25 words. The consent screens for Cloud suggestions, "Who
  can see what" and Gravatar may use up to 35 words for each item.
- A screen says a reassurance ("read-only", "on this iPhone", "end-to-end encrypted") once.
- Instructions use the imperative and keep the exact names of buttons, switches, settings
  and paths ("Profile › Bank alerts", "Run Immediately").

**Keep.** Do not remove these facts to make a line shorter:

- what a destructive action loses, and whether you can undo it;
- the facts on a consent screen: what is sent, what is not sent, who keeps what;
- what unlocks the data (a passkey or the 12 words, not a password, on a new iPhone);
- amounts, counts, dates and limits ("10 minutes; 5 tries").

**Info tips.** `InfoTip` and `.infoTip(_:about:)` (HasalaDesign) show an ⓘ button that
opens a short popover. Use a tip for a detail that some people want and most do not: how the
server stays blind, why a code alone is not proof, what a currency peg means. Use at most one
tip for each card or section. Do not put an instruction, or the result of a destructive
action, only in a tip. `about:` completes the VoiceOver label "About …".

**Measure.** On 2026-11-10 the visible copy (not tips, debug tools or SVG data) went from
258 to 56 strings of 15 words or more, and from 9,720 to 5,998 words in strings of 8 words or
more.
