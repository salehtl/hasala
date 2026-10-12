package auth

import (
	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/pushv2"
)

// Wake is who a committed security action wakes (spec 02 §9.3, §12.5): every
// device of the account except the writer Except ("" wakes them all), and
// Revoked, the APNs tokens of the sessions the action signed out. Those were
// read from the rows the action deleted, inside its transaction, because once
// it commits nothing else can find them; a device woken through one meets 401
// and shows its "signed out" notice. A zero Wake (no UserID) wakes nothing,
// and a rolled-back action returns none.
type Wake struct {
	UserID  uuid.UUID
	Except  string
	Revoked []pushv2.Target
}

// wakeFor builds the Wake of an action on userID by the writer except.
func wakeFor(userID uuid.UUID, except string, revoked []pushv2.Target) Wake {
	return Wake{UserID: userID, Except: except, Revoked: revoked}
}
