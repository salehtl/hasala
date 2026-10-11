package parse

import (
	"errors"
	"testing"
)

const dibCardPurchase = `معاملة بطاقة ائتمان
عزيزي المتعامل,
إشعار مشتريات بتاريخ 11-03-2025 08:47 بالتفاصيل التالية.
رقم البطاقة
400000XXXXXX9999
بطاقة الإئتمان
المبلغ
AED 187.25
الدفع الى
ACME TRADING LLC
إجمالي الرصيد المتوفر
3,120.55`

const dibDebit = `إشعار خصم
عزيزي المتعامل,
إشعار خصم من الحساب بتاريخ 11-03-2025 بالتفاصيل التالية.
المبلغ
AED 133.40
من حساب
009-123-XXXX456-09
حساب جاري
المعاملة
EXAMPLE UTILITY PAYMENT
الحالة
تمت بنجاح`

const dibDeposit = `إشعار إيداع
عزيزي المتعامل,
إشعار إيداع فى الحساب بتاريخ 11-03-2025 بالتفاصيل التالية.
المبلغ
AED 6,250.00
من حساب
009-321-XXXX654-09
حساب جاري
المعاملة
EXAMPLE SALARY PAYMENT
الحالة
تمت بنجاح`

func TestDIBMatches(t *testing.T) {
	p := DIBParser{}
	if !p.Matches("DIB.notification@dib.ae", "DIB Notification") {
		t.Error("should match DIB sender")
	}
	if p.Matches("alerts@other.com", "x") {
		t.Error("should not match other senders")
	}
}

func TestDIBCardPurchase(t *testing.T) {
	got, err := DIBParser{}.Parse("", dibCardPurchase)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.AmountFils != 18725 {
		t.Errorf("amount = %d, want 18725", got.AmountFils)
	}
	if got.Direction != DirectionDebit {
		t.Errorf("direction = %q, want debit", got.Direction)
	}
	if got.MerchantRaw != "ACME TRADING LLC" {
		t.Errorf("merchant = %q", got.MerchantRaw)
	}
	if got.Last4 != "9999" {
		t.Errorf("last4 = %q, want 9999", got.Last4)
	}
	if got.PostedAt.Day() != 11 || got.PostedAt.Month() != 3 {
		t.Errorf("date = %s", got.PostedAt)
	}
	if got.Tier != TierTemplate || got.Confidence < 0.9 {
		t.Errorf("tier/conf = %q/%v", got.Tier, got.Confidence)
	}
}

func TestDIBDebit(t *testing.T) {
	got, err := DIBParser{}.Parse("", dibDebit)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.AmountFils != 13340 || got.Direction != DirectionDebit {
		t.Errorf("got %d/%s", got.AmountFils, got.Direction)
	}
	if got.MerchantRaw != "EXAMPLE UTILITY PAYMENT" {
		t.Errorf("desc = %q", got.MerchantRaw)
	}
	// Account "009-123-XXXX456-09" → digits "00912345609" → last4 "5609"
	if got.Last4 != "5609" {
		t.Errorf("last4 = %q, want 5609 (trailing acct digits)", got.Last4)
	}
}

func TestDIBDeposit(t *testing.T) {
	got, err := DIBParser{}.Parse("", dibDeposit)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.AmountFils != 625000 {
		t.Errorf("amount = %d, want 625000", got.AmountFils)
	}
	if got.Direction != DirectionCredit {
		t.Errorf("direction = %q, want credit", got.Direction)
	}
}

func TestDIBUnrecognizedReturnsError(t *testing.T) {
	if _, err := (DIBParser{}).Parse("", "just some text with no DIB anchors"); err == nil {
		t.Error("expected error when anchors absent")
	}
}

// dibDebitNoDate is dibDebit with the بتاريخ (date) anchor dropped from the
// intro sentence — amount/merchant anchors still match, but the date anchor
// is missing.
const dibDebitNoDate = `إشعار خصم
عزيزي المتعامل,
إشعار خصم من الحساب بالتفاصيل التالية.
المبلغ
AED 133.40
من حساب
009-123-XXXX456-09
حساب جاري
المعاملة
EXAMPLE UTILITY PAYMENT
الحالة
تمت بنجاح`

func TestDIBMissingDateAnchorReturnsError(t *testing.T) {
	// DIB must fail hard when its date anchor is absent, rather than leaving
	// PostedAt zero — a zero PostedAt is the template-tier fallback opt-in
	// signal (currently reserved for ENBDAlertParser), and DIB must not
	// silently inherit it.
	if _, err := (DIBParser{}).Parse("", dibDebitNoDate); err == nil {
		t.Error("expected error when date anchor is missing")
	}
}

const dibTransferOut = `إشعار تحويل
عزيزي المتعامل,
إشعار تحويل من الحساب بتاريخ 12-03-2025 بالتفاصيل التالية.
المبلغ
AED 300.00
من حساب
009-123-XXXX456-09
حساب جاري
المعاملة
EXAMPLE FUND TRANSFER DEBIT
الحالة
تمت بنجاح`

const dibTransferIn = `إشعار تحويل
عزيزي المتعامل,
إشعار تحويل فى الحساب بتاريخ 12-03-2025 بالتفاصيل التالية.
المبلغ
AED 640.00
من حساب
009-321-XXXX654-09
حساب جاري
المعاملة
EXAMPLE FUNDS TRANSFER CREDIT
الحالة
تمت بنجاح`

func TestDIBTransferOutgoingIsDebit(t *testing.T) {
	got, err := DIBParser{}.Parse("", dibTransferOut)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.Direction != DirectionDebit {
		t.Errorf("direction = %q, want debit (outgoing transfer / desc suffix DEBIT)", got.Direction)
	}
	if !got.IsTransfer {
		t.Error("expected IsTransfer = true")
	}
}

func TestDIBTransferIncomingIsCredit(t *testing.T) {
	got, err := DIBParser{}.Parse("", dibTransferIn)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got.Direction != DirectionCredit {
		t.Errorf("direction = %q, want credit (incoming transfer / desc suffix CREDIT)", got.Direction)
	}
}

// dibEnglishMoneyTransfer is DIB's English "Money Transfer" confirmation — a
// duplicate notification for a fund transfer already recorded from its
// sibling Arabic account-transaction email. Layout from a real message; every
// identifier below is synthetic.
const dibEnglishMoneyTransfer = `Money Transfer
Dear Customer,
This is to notify you that a Domestic Fund Transfer transaction has been initiated on 02-08-2026 12:58:19 with the following details.
Amount
9,780.00
From
AE9801234XXXXXX9
[From Account FRM]
To
AE0400012345678XXXXX999
Beneficiary Bank
National Bank of Abu Dhabi
Status
Credited to beneficiary
Reference Number
[Reference Number]
If you have not initiated this request, kindly change your password and inform the Bank by calling +97146092222.
This is the new design of automated notification emails that you receive from Dubai Islamic Bank (DIB).`

func TestDIBEnglishMoneyTransferReturnsIgnoreError(t *testing.T) {
	_, err := DIBParser{}.Parse("DIB Notification", dibEnglishMoneyTransfer)
	if !errors.Is(err, ErrIgnoreEmail) {
		t.Fatalf("err = %v, want ErrIgnoreEmail", err)
	}
}
