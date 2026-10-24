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
// Every one is English, to exactly one address, with a plain-text part and an
// HTML part in the shared layout (html.go, Paper's P2 row 14.7). The text
// starts with a greeting line and a blank line and ends with the footer. The
// only substitutions are the code, the time, the freeze link, the
// passkey/password word and the greeting's first name. No other URL (the HTML
// layout adds only the logo and its hasala.app support and privacy links), no
// account data, no device name.

// Footer is the S-35 footer every account email ends with.
const Footer = "—\nHasala never asks for your recovery phrase, your password or a code by email, " +
	"by phone or on a website. Questions? Reply to this email."

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

// The HTML footer's "You're getting this because …" lines. None names the
// address.
const (
	whyCode    = "You're getting this because someone entered this address in Hasala."
	whyAlert   = "You're getting this security alert because of a change to your Hasala account. Security alerts can't be turned off."
	whyDeleted = "You're getting this because the Hasala account for this address was deleted. We won't email you again."
)

// compose builds one message: the text part from lines, the HTML part from p
// (whose Lead is lines when p sets neither Lead nor Paras). The layout and
// the account template are embedded, and TestTheTemplatesAreContentFree
// renders every account email, so render does not fail at run time; if it
// ever did, the message still goes, as text only.
func compose(to, subject, name string, p page, lines ...string) Message {
	p.Title, p.Greeting = subject, Greeting(name)
	if p.Lead == nil && p.Paras == nil {
		p.Lead = lines
	}
	html, _ := p.render()
	return Message{To: to, Subject: subject, Text: body(name, lines...), HTML: html}
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
	heading := "Your code"
	switch purpose {
	case "password_reset":
		heading = "Reset your password"
	case "recovery":
		heading = "Get back into your account"
	}
	const never = "Only type it into the Hasala app. Hasala will never ask you for it by phone, by email or on a website."
	p := page{Heading: heading, Why: whyCode, Lead: []string{line}, Code: code, Paras: []string{never}}
	return compose(to, "Your Hasala code", name, p,
		line, "Your Hasala code is "+code+". It works for 10 minutes. "+never), nil
}

// AddressInUse is the notice sent instead of a code to an address that already
// has an account (#43, #60). It greets no one by name.
func AddressInUse(to string) Message {
	return compose(to, "Your Hasala email address", "",
		page{Heading: "This address already has an account", Why: whyCode},
		"Someone tried to use this email address for a new Hasala account. It already belongs to a "+
			"Hasala account, so nothing has changed. If this was you, sign in to Hasala instead.")
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
	return strings.HasPrefix(subkind, "new_sign_in_") || strings.HasPrefix(subkind, "recovery_used_") ||
		subkind == "phrase_viewed"
}

// Alert renders a security alert. freezeLink is the full link for the two
// subkinds that carry one and "" otherwise.
func Alert(to, subkind string, at time.Time, name, freezeLink string) (Message, error) {
	when := When(at)
	if AlertCarriesFreezeLink(subkind) && freezeLink == "" {
		return Message{}, fmt.Errorf("mail: alert %s needs a freeze link", subkind)
	}
	alert := func(subject, heading string, lines ...string) (Message, error) {
		return compose(to, subject, name, page{Heading: heading, Why: whyAlert}, lines...), nil
	}
	// withFreeze ends the text with the freeze link; the HTML puts it in the
	// "This wasn't me" panel's button.
	withFreeze := func(subject, heading string, lines ...string) (Message, error) {
		text := append(lines,
			"If it wasn't, freeze your account now. Everyone will be signed out until you confirm it's you: "+freezeLink,
			"This link works for 7 days and can only freeze your account.")
		p := page{Heading: heading, Why: whyAlert, Lead: lines, Freeze: freezeLink}
		return compose(to, subject, name, p, text...), nil
	}
	switch subkind {
	case "new_sign_in_passkey", "new_sign_in_password":
		method := strings.TrimPrefix(subkind, "new_sign_in_")
		return withFreeze("New sign-in to Hasala", "New sign-in to your account",
			"Your Hasala account was signed in on an iPhone with your "+method+" on "+when+".",
			"If this was you, there's nothing to do.")
	case "recovery_used_passkey", "recovery_used_password":
		method := strings.TrimPrefix(subkind, "recovery_used_")
		return withFreeze("Your Hasala recovery phrase was used", "Your recovery phrase was used",
			"Your recovery phrase was used to get back into your Hasala account on "+when+
				", and a new "+method+" was added.",
			"Your old passkeys and your old password were removed, and every other device was signed out.")
	case "new_passkey":
		return alert("New passkey for Hasala", "New passkey added",
			"A new passkey was added to your Hasala account on "+when+".", notYou)
	case "password_set", "password_changed", "password_removed", "password_reset":
		verb := strings.TrimPrefix(subkind, "password_")
		return alert("Your Hasala password changed", "Your password was changed",
			"Your Hasala password was "+verb+" on "+when+". Other devices were signed out.", notYou)
	case "phrase_viewed":
		return withFreeze("Your Hasala recovery phrase was shown", "Your recovery phrase was viewed",
			"Your recovery phrase was shown in the Hasala app on "+when+".",
			"If this was you, there's nothing to do.")
	case "device_removed":
		return alert("A device was removed from Hasala", "Device removed",
			"An iPhone was removed from your Hasala account on "+when+".", notYou)
	case "email_changed_new":
		return alert("This is now your Hasala email address", "This is now your Hasala email",
			"This address became the email address of a Hasala account on "+when+".")
	case "email_changed_old":
		return alert("Your Hasala email address changed", "Your email address changed",
			"Your Hasala account stopped using this email address on "+when+
				". You won't get Hasala email here any more.", notYou)
	case "account_frozen":
		return alert("Your Hasala account is frozen", "Your account is frozen",
			"Your Hasala account was frozen on "+when+". Everyone was signed out. To unfreeze it, sign in on "+
				"one of your iPhones with a passkey, or with your password, that you had before the freeze.")
	case "account_unfrozen":
		return alert("Your Hasala account is unfrozen", "Your account is unfrozen",
			"Your Hasala account was unfrozen on "+when+".", notYou)
	}
	return Message{}, fmt.Errorf("mail: no alert %q", subkind)
}

// Deleted is the goodbye email after a purge. It greets no one by name: the
// account, and so the name, is gone by the time it is sent.
func Deleted(to string, at time.Time) Message {
	const (
		passkey = "Your Hasala passkey may still show in the Passwords app on your iPhone. You can delete it there."
		notMe   = "Didn't do this? Tell us at hasala.app/support. We can't bring deleted data back, but we'll find out what happened."
	)
	p := page{Heading: "Your account is deleted.", Why: whyDeleted,
		Lead: []string{"Your Hasala account and its data were deleted from our server on " + When(at) + "."},
		// Paper's summary rows. The backups expire within 30 days, so the
		// sealed backup is gone by the day 30 days on (UAE time).
		Rows: []Row{{"Budget, plan, rules", "Erased"},
			{"Sealed backup", "Gone from backups by " + at.Add(30*24*time.Hour).In(uae).Format("2 Jan")}},
		Paras: []string{passkey}, Small: notMe}
	return compose(to, "Your Hasala account was deleted", "", p,
		"Your Hasala account and its data were deleted from our server on "+When(at)+
			". Encrypted backups expire within 30 days.", passkey, notMe)
}
