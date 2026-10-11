// Package pushv2 delivers content-free wakes to a user's devices (spec 02 §12).
// The APNs sender (apns.go) and the wake debouncer (wake.go) are WS-4's; this
// file is the seam they plug into. ledgerd's Expo and Web Push (VAPID)
// transports are gone (spec 02 §2.3: Web Push carried an SSRF, and the PWA it
// served is retired).
//
// # The one rule
//
// A push payload carries no content: no amount, no merchant, no count, no
// category, ever. A notification is rendered on a lock screen and travels
// through Apple's push service, outside the end-to-end encryption that covers
// the op log; even a count is a spending-frequency signal. A Notifier is
// handed a user id and nothing else, so no code path here could interpolate
// one.
package pushv2

import (
	"context"
	"errors"

	"github.com/google/uuid"
)

// Notifier wakes a user's devices.
type Notifier interface {
	Notify(ctx context.Context, userID uuid.UUID) error
}

// Disabled is the no-op notifier, and the default while apns.enabled is false
// (spec 02 §18.2: the token routes stay mounted, the waker does nothing).
type Disabled struct{}

// Notify does nothing, successfully.
func (Disabled) Notify(context.Context, uuid.UUID) error { return nil }

// Multi notifies through every member. Every member is called even if an
// earlier one fails, and the errors are joined: the members are independent
// audiences, and one must not go unnotified because another failed.
type Multi []Notifier

// Notify implements Notifier over every member.
func (m Multi) Notify(ctx context.Context, userID uuid.UUID) error {
	var errs []error
	for _, n := range m {
		if n == nil {
			continue
		}
		if err := n.Notify(ctx, userID); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
