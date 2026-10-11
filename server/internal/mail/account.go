package mail

import (
	"fmt"
	"strings"
	"time"
)

// account.go is spec 02 §14.6's account emails (codes, the address-in-use
// notice, security alerts, the goodbye), rendered by internal/auth's renderers
// and sent only through internal/mailq. Spec 07's kinds (waitlist, invite,
// bank_supported, test) are mailq's templates.
//
// Every one is plain text, English, to
// exactly one address; it starts with a greeting line and a blank line and ends
// with the footer. The only substitutions are the code, the time, the freeze
// link, the passkey/password word and the greeting's first name. No other URL,
// no account data, no device name.

// Footer is the S-35 footer every account email ends with.
const Footer = "—\nHasala never asks for your recovery phrase, your password or a code by email, " +
	"by phone or on a website. Don't reply to this email."

// DefaultFreezeURL is the freeze page; the token goes in the fragment.
const DefaultFreezeURL = "https://hasala.app/freeze"

// uae is the fixed UTC+4 clock every email writes times in.
var uae = time.FixedZone("UAE", 4*60*60)

// When writes t as "Sun 11 Oct 2026, 13:40 UAE time".
func When(t time.Time) string {
	return t.In(uae).Format("Mon 2 Jan 2006, 15:04") + " UAE time"
}

// Greeting is "Hi {first}," for a name, else "Hi,". first is the stored
// display name up to its first space (Q19).
func Greeting(displayName string) string {
	name := strings.TrimSpace(displayName)
	if name == "" {
		return "Hi,"
	}
	if i := strings.IndexByte(name, ' '); i > 0 {
		name = name[:i]
	}
	return "Hi " + name + ","
}

func body(greetName string, lines ...string) string {
	var b strings.Builder
	b.WriteString(Greeting(greetName))
	b.WriteString("\n\n")
	for _, l := range lines {
		b.WriteString(l)
		b.WriteString("\n")
	}
	b.WriteString("\n")
	b.WriteString(Footer)
	b.WriteString("\n")
	return b.String()
}

// codePurposeLines are the first lines of a code email, by purpose.
var codePurposeLines = map[string]string{
	"signup":           "Use this code to create your Hasala account.",
	"email_verify":     "Use this code to confirm this is still your Hasala email address.",
	"email_change_old": "Use this code to move your Hasala account to a new email address.",
	"email_change_new": "Use this code to make this your Hasala email address.",
	"password_reset":   "Use this code to reset your Hasala password.",
	"recovery":         "Use this code, with your recovery phrase, to get back into your Hasala account.",
}

// CodeGreetsByName says whether a code email of this purpose greets the
// account holder by name (spec 02 §14.6): only when it concerns an existing
// account and goes to an address that account verified.
func CodeGreetsByName(purpose string) bool {
	switch purpose {
	case "email_verify", "password_reset", "recovery", "email_change_old":
		return true
	}
	return false
}

// CodeKind is mail_log.kind for a code of this purpose.
func CodeKind(purpose string) string {
	switch purpose {
	case "password_reset":
		return "reset_code"
	case "recovery":
		return "recovery_code"
	}
	return "code"
}

// Code renders a code email. name is "" unless CodeGreetsByName(purpose).
func Code(to, purpose, code, name string) (Message, error) {
	line, ok := codePurposeLines[purpose]
	if !ok {
		return Message{}, fmt.Errorf("mail: no code email for purpose %q", purpose)
	}
	if !CodeGreetsByName(purpose) {
		name = ""
	}
	return Message{To: to, Subject: "Your Hasala code", Text: body(name, line,
		"Your Hasala code is "+code+". It works for 10 minutes. Only type it into the Hasala app. "+
			"Hasala will never ask you for it by phone, by email or on a website.")}, nil
}

// AddressInUse is the notice sent instead of a code to an address that already
// has an account (#43, #60). It greets no one by name.
func AddressInUse(to string) Message {
	return Message{To: to, Subject: "Your Hasala email address", Text: body("",
		"Someone tried to use this email address for a new Hasala account. It already belongs to a "+
			"Hasala account, so nothing has changed. If this was you, sign in to Hasala instead.")}
}

// notYou points at the screen every build has. The in-app freeze is not in
// every build (the beta hides it), so the line names the place, not the
// button (spec 02 §14.6's wording names the freeze).
const notYou = "If this wasn't you, open Hasala on one of your iPhones and go to Profile › Sign-in & security."

// AlertSubkinds is the closed set of alert subkinds (spec 02 §14.6).
var AlertSubkinds = []string{
	"new_sign_in_passkey", "new_sign_in_password", "recovery_used_passkey", "recovery_used_password",
	"new_passkey", "password_set", "password_changed", "password_removed", "password_reset",
	"phrase_viewed", "device_removed", "email_changed_new", "email_changed_old",
	"account_frozen", "account_unfrozen",
}

// AlertCarriesFreezeLink says whether an alert of this subkind carries a
// freeze link (and so needs a token minted at send time).
func AlertCarriesFreezeLink(subkind string) bool {
	return strings.HasPrefix(subkind, "new_sign_in_") || strings.HasPrefix(subkind, "recovery_used_")
}

// Alert renders a security alert. freezeLink is the full link for the two
// subkinds that carry one and "" otherwise.
func Alert(to, subkind string, at time.Time, name, freezeLink string) (Message, error) {
	when := When(at)
	freeze := func() []string {
		return []string{
			"If it wasn't, freeze your account now. Everyone will be signed out until you confirm it's you: " + freezeLink,
			"This link works for 7 days and can only freeze your account.",
		}
	}
	if AlertCarriesFreezeLink(subkind) && freezeLink == "" {
		return Message{}, fmt.Errorf("mail: alert %s needs a freeze link", subkind)
	}
	switch subkind {
	case "new_sign_in_passkey", "new_sign_in_password":
		method := strings.TrimPrefix(subkind, "new_sign_in_")
		lines := append([]string{
			"Your Hasala account was signed in on an iPhone with your " + method + " on " + when + ".",
			"If this was you, there's nothing to do.",
		}, freeze()...)
		return Message{To: to, Subject: "New sign-in to Hasala", Text: body(name, lines...)}, nil
	case "recovery_used_passkey", "recovery_used_password":
		method := strings.TrimPrefix(subkind, "recovery_used_")
		lines := append([]string{
			"Your recovery phrase was used to get back into your Hasala account on " + when +
				", and a new " + method + " was added.",
		}, freeze()...)
		return Message{To: to, Subject: "Your Hasala recovery phrase was used", Text: body(name, lines...)}, nil
	case "new_passkey":
		return Message{To: to, Subject: "New passkey for Hasala", Text: body(name,
			"A new passkey was added to your Hasala account on "+when+".", notYou)}, nil
	case "password_set", "password_changed", "password_removed", "password_reset":
		verb := strings.TrimPrefix(subkind, "password_")
		return Message{To: to, Subject: "Your Hasala password changed", Text: body(name,
			"Your Hasala password was "+verb+" on "+when+". Other devices were signed out.", notYou)}, nil
	case "phrase_viewed":
		return Message{To: to, Subject: "Your Hasala recovery phrase was shown", Text: body(name,
			"Your recovery phrase was shown in the Hasala app on "+when+".", notYou)}, nil
	case "device_removed":
		return Message{To: to, Subject: "A device was removed from Hasala", Text: body(name,
			"An iPhone was removed from your Hasala account on "+when+".", notYou)}, nil
	case "email_changed_new":
		return Message{To: to, Subject: "This is now your Hasala email address", Text: body(name,
			"This address became the email address of a Hasala account on "+when+".")}, nil
	case "email_changed_old":
		return Message{To: to, Subject: "Your Hasala email address changed", Text: body(name,
			"Your Hasala account stopped using this email address on "+when+
				". You won't get Hasala email here any more.", notYou)}, nil
	case "account_frozen":
		return Message{To: to, Subject: "Your Hasala account is frozen", Text: body(name,
			"Your Hasala account was frozen on "+when+". Everyone was signed out. To unfreeze it, sign in on "+
				"one of your iPhones with a passkey, or with your password, that you had before the freeze.")}, nil
	case "account_unfrozen":
		return Message{To: to, Subject: "Your Hasala account is unfrozen", Text: body(name,
			"Your Hasala account was unfrozen on "+when+".", notYou)}, nil
	}
	return Message{}, fmt.Errorf("mail: no alert %q", subkind)
}

// Deleted is the goodbye email after a purge.
func Deleted(to string, at time.Time) Message {
	return Message{To: to, Subject: "Your Hasala account was deleted", Text: body("",
		"Your Hasala account and its data were deleted from our server on "+When(at)+
			". Encrypted backups expire within 30 days.")}
}
