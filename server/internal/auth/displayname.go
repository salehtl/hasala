package auth

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

// Display-name refusals (400 bad_name). The detail names the rule, never the
// name.
var (
	ErrBadName           = errors.New("auth: display name refused")
	ErrBadNameLength     = errors.New("display_name: length")
	ErrBadNameCharacters = errors.New("display_name: characters")
)

// DisplayName is spec 02 §10.7.4's rule, the only writer of
// users.display_name and signup_ceremonies.display_name. It folds every run
// of Unicode white space into one U+0020 and trims both ends, and otherwise
// never "fixes" a name:
//
//  1. valid UTF-8, at most 256 bytes;
//  2. 1–64 runes after folding;
//  3. every rune a letter, a mark, U+0020, ' (U+0027), ’ (U+2019), - or .;
//  4. a period only before a space or at the end;
//  5. at least one letter.
//
// Every name it accepts also passes spec 01 §4.11's name_ok (the floor), which
// it checks last as a tripwire. No Unicode normalization happens here (fence
// 1 keeps golang.org/x/text out); the device sends NFC.
func DisplayName(in string) (string, error) {
	if !utf8.ValidString(in) || len(in) > 256 {
		return "", errors.Join(ErrBadName, ErrBadNameCharacters)
	}
	name := strings.Join(strings.FieldsFunc(in, unicode.IsSpace), " ")
	n := utf8.RuneCountInString(name)
	if n < 1 || n > 64 {
		return "", errors.Join(ErrBadName, ErrBadNameLength)
	}
	letters := 0
	rs := []rune(name)
	for i, r := range rs {
		switch {
		case unicode.IsLetter(r):
			letters++
		case unicode.IsMark(r), r == ' ', r == '\'', r == '’', r == '-':
		case r == '.':
			if i+1 < len(rs) && rs[i+1] != ' ' {
				return "", errors.Join(ErrBadName, ErrBadNameCharacters)
			}
		default:
			return "", errors.Join(ErrBadName, ErrBadNameCharacters)
		}
	}
	if letters == 0 || !keyproto.NameOK(name) {
		return "", errors.Join(ErrBadName, ErrBadNameCharacters)
	}
	return name, nil
}
