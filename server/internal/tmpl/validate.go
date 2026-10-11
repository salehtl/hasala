package tmpl

import (
	"errors"
	"fmt"
	"strings"
)

// ErrInvalidDefinition means a definition did not pass the publish gate. It
// wraps the specific reasons; the message names them.
var ErrInvalidDefinition = errors.New("tmpl: definition rejected by the publish gate")

// ValidateForPublish is everything that must hold before a definition may
// ship. ledgerd's template store and its publication log are gone (spec 02
// D-2: the server no longer distributes templates); the gate stays because
// the embedded seed (internal/tmpl/seed) and the Swift template engine are
// held to it.
//
// Three steps, in this order:
//
//  1. The DIALECT gate, over every pattern. It runs first and on its own so
//     that removing it is a visible deletion rather than an invisible
//     consequence of refactoring step 2 (which happens to call ValidatePattern
//     today).
//  2. The definition validator: field/type pairings, required fields, the
//     override budget, the sender-domain requirement.
//  3. Compile: the executor's own contract. A definition that validates but
//     that the executor cannot reach a value through is a template that ships
//     and silently matches nothing.
func ValidateForPublish(d Definition) error {
	for i, x := range d.Extract {
		for j, p := range x.Patterns {
			if errs := ValidatePattern(p, x.Flags); len(errs) > 0 {
				return fmt.Errorf("%w: extract[%d].patterns[%d]: %s",
					ErrInvalidDefinition, i, j, strings.Join(Codes(errs), ", "))
			}
		}
	}
	if errs := ValidateDefinition(d); len(errs) > 0 {
		return fmt.Errorf("%w: %w", ErrInvalidDefinition, errors.Join(errs...))
	}
	if _, err := Compile(d); err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidDefinition, err)
	}
	return nil
}
