package contract

import (
	"errors"
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// isPySpace is Python's str.isspace for one character.
func isPySpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }

// pySplitLines is Python's str.splitlines(): it splits on \n, \r, \r\n, \v, \f, \x1c-\x1e, \x85,
// U+2028 and U+2029, and drops a final empty element.
func pySplitLines(s string) []string {
	var lines []string
	start := 0
	rs := []rune(s)
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		switch r {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
		case '\r':
			lines = append(lines, string(rs[start:i]))
			if i+1 < len(rs) && rs[i+1] == '\n' {
				i++
			}
			start = i + 1
			continue
		default:
			continue
		}
		lines = append(lines, string(rs[start:i]))
		start = i + 1
	}
	if start < len(rs) {
		lines = append(lines, string(rs[start:]))
	}
	return lines
}

// confusables maps letters that look like a Latin letter onto it. It is a documented, deliberately
// BEST-EFFORT table, NOT the full Unicode UTS #39 confusables set (golang.org/x/text carries no such
// data): no table of this kind is complete, and a look-alike outside it is treated as ordinary
// content - still inside the delimited block and below the template's own header ("data, not
// instructions"). The neutralisation is defence in depth, not a proof (B2-04, B3-02). Keys are the
// lower-case forms (the fold lower-cases before the lookup, and Cherokee is listed in both cases).
// TestB4ConfusableTableIsComplete fails if a listed look-alike stops folding to its letter.
var confusables = map[rune]rune{
	// Greek
	'α': 'a', 'ε': 'e', 'ι': 'i', 'κ': 'k', 'ν': 'v', 'ο': 'o', 'ρ': 'p', 'τ': 't', 'υ': 'u', 'χ': 'x', 'η': 'n', 'ϲ': 'c',
	'γ': 'y', 'μ': 'u', 'ω': 'w', 'ϳ': 'j', 'ϵ': 'e', 'ϱ': 'p',
	// Cyrillic
	'а': 'a', 'в': 'b', 'е': 'e', 'к': 'k', 'м': 'm', 'н': 'h', 'о': 'o', 'р': 'p', 'с': 'c', 'т': 't', 'у': 'y', 'х': 'x',
	'і': 'i', 'ј': 'j', 'ѕ': 's', 'ԛ': 'q', 'ԝ': 'w', 'ӏ': 'l', 'г': 'r', 'һ': 'h', 'ѵ': 'v', 'ԁ': 'd',
	// Latin: dotless i, dotless j, IPA look-alikes
	'ı': 'i', 'ȷ': 'j', 'ɑ': 'a', 'ɡ': 'g', 'ɩ': 'i',
	// Latin small capitals
	'ᴀ': 'a', 'ʙ': 'b', 'ᴄ': 'c', 'ᴅ': 'd', 'ᴇ': 'e', 'ꜰ': 'f', 'ɢ': 'g', 'ʜ': 'h', 'ɪ': 'i', 'ᴊ': 'j', 'ᴋ': 'k',
	'ʟ': 'l', 'ᴍ': 'm', 'ɴ': 'n', 'ᴏ': 'o', 'ᴘ': 'p', 'ʀ': 'r', 'ꜱ': 's', 'ᴛ': 't', 'ᴜ': 'u', 'ᴠ': 'v', 'ᴡ': 'w',
	'ʏ': 'y', 'ᴢ': 'z',
	// Armenian
	'ս': 'u', 'օ': 'o', 'ո': 'n', 'ց': 'g', 'հ': 'h', 'ք': 'p',
	// Cherokee (capitals; the lower-case forms are added in init)
	'\u13aa': 'a', '\u13f4': 'b', '\u13df': 'c', '\u13a0': 'd', '\u13ac': 'e', '\u13c0': 'g', '\u13bb': 'h',
	'\u13d6': 'i', '\u13ab': 'j', '\u13e6': 'k', '\u13de': 'l', '\u13b7': 'm', '\u13e2': 'p', '\u13a1': 'r',
	'\u13da': 's', '\u13a2': 't', '\u13e9': 'v', '\u13b3': 'w', '\u13c3': 'z',
	// Lisu
	'\ua4ee': 'a', '\ua4d0': 'b', '\ua4da': 'c', '\ua4d3': 'd', '\ua4f0': 'e', '\ua4d6': 'g', '\ua4e7': 'h',
	'\ua4f2': 'i', '\ua4d9': 'j', '\ua4d7': 'k', '\ua4e1': 'l', '\ua4df': 'm', '\ua4e0': 'n', '\ua4f3': 'o',
	'\ua4d1': 'p', '\ua4e2': 's', '\ua4d4': 't', '\ua4f4': 'u', '\ua4e6': 'v', '\ua4ea': 'w', '\ua4eb': 'x',
	'\ua4ec': 'y', '\ua4dc': 'z',
	// box-drawing double line used as a delimiter look-alike
	'═': '=',
}

func init() {
	// the lower-case Cherokee letters (U+AB70..U+ABBF) sit at +0xAB70-0x13A0 from their capitals
	for r, l := range confusables {
		if r >= 0x13a0 && r <= 0x13ef {
			confusables[r-0x13a0+0xab70] = l
		}
	}
}

// invisibleForMatch are the code points that render as nothing (or as blank space) but are NOT in
// Unicode category Cf/Cc/Mn/Me/Z*, so the category rule alone does not drop them: the Hangul
// fillers, the Braille blank, the Mongolian vowel separator. They are skipped when MATCHING a line
// only; content is never altered (B3-02).
func invisibleForMatch(r rune) bool {
	switch r {
	case 0x115f, 0x1160, 0x3164, 0xffa0, 0x2800, 0x180e, 0x034f, 0x17b4, 0x17b5:
		return true
	}
	return false
}

// isListPrefix: every dash (Unicode Pd), the minus sign U+2212, the two-em dash U+2E3A, bullets and markdown marks.
func isListPrefix(r rune) bool {
	return unicode.Is(unicode.Pd, r) || r == 0x2212 || r == 0x2e3a || strings.ContainsRune("*_`>#+~|\u2022\u00b7", r)
}

// foldLine is the structural fingerprint of a line, used to MATCH only (the rewrite in Neutralise*
// keeps the original line): compatibility-decomposed (full-width and circled forms become ASCII);
// without ANY character in the categories Cf (format: zero-width, bidi, soft hyphen, BOM, variation
// selectors, tag chars), Cc (controls; a tab is a blank), Mn/Me (combining and enclosing marks) or
// Zs/Zl/Zp (all blanks, anywhere in the line), without the invisible non-Cf fillers
// (invisibleForMatch); tag characters U+E0020..E007E map to the ASCII they spell; lower-cased;
// look-alikes mapped to Latin (confusables); and without leading list/markdown prefix characters
// (all dashes Pd, the minus sign, bullets, markdown emphasis / quote / heading marks).
func foldLine(line string) string { return foldLineOpt(line, false) }

// foldLineOpt is foldLine; keepSpace keeps the ASCII space (used only for the "===" delimiter test:
// the neutraliser has already broken every "===" into "= = =", which must not be re-joined).
func foldLineOpt(line string, keepSpace bool) string {
	var b strings.Builder
	for _, r := range norm.NFKD.String(line) {
		if r >= 0xe0020 && r <= 0xe007e { // tag characters spell ASCII invisibly
			r -= 0xe0000
		}
		if keepSpace && r == ' ' {
			b.WriteRune(r)
			continue
		}
		switch {
		case unicode.Is(unicode.Cf, r), unicode.Is(unicode.Cc, r), unicode.Is(unicode.Mn, r), unicode.Is(unicode.Me, r),
			unicode.Is(unicode.Zs, r), unicode.Is(unicode.Zl, r), unicode.Is(unicode.Zp, r), invisibleForMatch(r), isPySpace(r):
			continue
		}
		if m, ok := confusables[r]; ok { // capitals of scripts whose small form is listed
			r = m
		} else {
			r = unicode.ToLower(r)
			if m, ok := confusables[r]; ok {
				r = m
			}
		}
		b.WriteRune(r)
	}
	return strings.TrimLeftFunc(b.String(), func(r rune) bool { return isListPrefix(r) || (keepSpace && r == ' ') })
}

// looksLikeMarker reports whether a state line could pass for an option marker ("A)", "(b)", "C.",
// "d:" ...), a question, an answer or a delimiter line - judged on the folded form of the line, so
// zero-width characters, full-width forms, markdown wrapping, accents and Greek/Cyrillic
// look-alikes do not hide it.
func looksLikeMarker(line string) bool {
	rs := []rune(foldLine(line))
	if len(rs) > 0 && (rs[0] == '(' || rs[0] == '[') {
		rs = rs[1:]
	}
	if len(rs) >= 2 && unicode.IsLetter(rs[0]) && strings.ContainsRune(").:]", rs[1]) {
		return true
	}
	low := string(rs)
	for _, p := range []string{"question", "answer", "state"} {
		if strings.HasPrefix(low, p) {
			return true
		}
	}
	return strings.HasPrefix(foldLineOpt(line, true), "===")
}

// NeutraliseState makes a state safe to embed in the delimited block: exotic line separators become
// newlines, delimiter lookalikes ("===") are broken up, and every line that could pass for an option
// marker / question / answer / delimiter line is prefixed with "| ". Content is preserved.
func NeutraliseState(state string) string {
	lines := pySplitLines(strings.ReplaceAll(state, "===", "= = ="))
	if len(lines) == 0 {
		lines = []string{""}
	}
	for i, l := range lines {
		if looksLikeMarker(l) {
			lines[i] = "| " + l
		}
	}
	return strings.Join(lines, "\n")
}

// NeutraliseInstructions makes the question text safe for the prompt exactly like the state: hidden
// controls and bidi characters are removed, exotic line separators become newlines, "===" lookalikes
// are broken up, and every line after the first that could pass for an option marker / question /
// answer / delimiter line is prefixed with "| " (the first line follows the template's own
// "Question: " and cannot forge anything). Content is preserved (review-2 B-04).
func NeutraliseInstructions(s string) string {
	lines := pySplitLines(strings.ReplaceAll(cleanText(s), "===", "= = ="))
	for i := 1; i < len(lines); i++ {
		if looksLikeMarker(lines[i]) {
			lines[i] = "| " + lines[i]
		}
	}
	return strings.Join(lines, "\n")
}

// RenderPrompt is the ONE prompt template, shared by the one-shot command and the network endpoint
// (FR-009). Question names are never rendered (they only key answers). More than 26 options cannot
// be rendered as letters and are an error.
func RenderPrompt(q ParsedQuestion, stateText string) (string, error) {
	for _, o := range q.Options {
		if o.Letter == "" {
			return "", errors.New("contract: more than 26 options cannot be rendered as letters")
		}
	}
	lines := []string{PromptHeader, "", StateBegin, NeutraliseState(cleanText(stateText)), StateEnd, "", "Question: " + NeutraliseInstructions(q.Instructions)}
	for _, o := range q.Options {
		lines = append(lines, o.Letter+") "+OneLine(o.Label)) // a key or label can never start a new line
	}
	lines = append(lines, "", "Answer with a single letter.", "Answer:")
	return strings.Join(lines, "\n"), nil
}

// StructuralFold exposes the match fold (tests and documentation only).
func StructuralFold(line string) string { return foldLine(line) }
