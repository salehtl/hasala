package parse

import "testing"

// Sanitised from a real Emirates NBD "Local Bank Transfer" notification, as it
// looks AFTER BodyText decodes MIME/quoted-printable and strips HTML to text.
const enbdLocalTransfer = `CIF: ***00***
Dear Sam Example Customer,
Here is a consolidated status of your Local Bank Transfer.
Transaction Date:
07/Jan/2026 03:14 PM
From Account:
012***34***56
Debit Amount:
AED 4,321.00
Transaction Amount:
AED 4,321.00
Exchange Rate:
N/A
Beneficiary Name:
Jane Example Beneficiary
Beneficiary Account / IBAN:
AE070331234567890123456
Status:
Success`

func TestENBDMatches(t *testing.T) {
	p := ENBDParser{}
	if !p.Matches("OnlineBanking@emiratesnbd.com", "Local Bank Transfer") {
		t.Fatal("should match the ENBD online-banking sender")
	}
	if p.Matches("DIB.notification@dib.ae", "x") {
		t.Fatal("should not match a different sender")
	}
}

func TestENBDParseLocalTransfer(t *testing.T) {
	got, err := ENBDParser{}.Parse("", enbdLocalTransfer)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.AmountFils != 432100 {
		t.Errorf("AmountFils = %d, want 432100", got.AmountFils)
	}
	if got.Currency != "AED" {
		t.Errorf("Currency = %q, want AED", got.Currency)
	}
	if got.Direction != DirectionDebit {
		t.Errorf("Direction = %q, want debit", got.Direction)
	}
	if got.MerchantRaw != "Jane Example Beneficiary" {
		t.Errorf("MerchantRaw = %q", got.MerchantRaw)
	}
	if got.Tier != TierTemplate {
		t.Errorf("Tier = %q, want template", got.Tier)
	}
	y, m, d := got.PostedAt.Date()
	if y != 2026 || m != 1 || d != 7 {
		t.Errorf("PostedAt = %v, want 2026-01-07", got.PostedAt)
	}
	if got.PostedAt.Hour() != 15 || got.PostedAt.Minute() != 14 {
		t.Errorf("PostedAt time = %02d:%02d, want 15:14", got.PostedAt.Hour(), got.PostedAt.Minute())
	}
	// A validated, parseable result (the whole point — the heuristic dropped these on the date).
	if err := Validate(got); err != nil {
		t.Errorf("Validate: %v", err)
	}
}

func TestParseENBDDate(t *testing.T) {
	d, err := ParseENBDDate("07/Jan/2026 03:14 PM")
	if err != nil {
		t.Fatalf("ParseENBDDate: %v", err)
	}
	if d.Year() != 2026 || d.Month() != 1 || d.Day() != 7 || d.Hour() != 15 {
		t.Errorf("got %v", d)
	}
	// date-only fallback
	if _, err := ParseENBDDate("07/Jan/2026"); err != nil {
		t.Errorf("date-only fallback failed: %v", err)
	}
}
