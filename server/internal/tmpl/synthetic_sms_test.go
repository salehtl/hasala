package tmpl

import (
	"strings"
	"testing"
)

const (
	smsPurchase   = "مشتريات بمبلغ"
	smsCard       = "من بطاقة"
	smsLimit      = ". الحد الائتماني المتاح"
	smsBalanceY   = "رصيدك الحالي"
	smsBalanceA   = "رصيدك الحالى"
	smsBalance    = "رصيدك"
	smsDebit      = "خصم"
	smsBimablagh  = "بمبلغ"
	smsMablagh    = "مبلغ"
	smsCardPay1   = "دفعة لبطاقة دبي الإسلامي الائتمانية"
	smsCardPay2   = "كدفعة للبطاقة"
	smsATM        = "خصم صراف آلي دولي بمبلغ"
	smsCredit     = "ايداع"
	smsCreditH    = "إيداع"
	smsSalary     = "راتب"
	smsMonth      = "شهر"
	smsDirham     = "درهم"
	smsDollar     = "دولار"
	smsRefund     = "تم إرجاع مبلغ"
	smsRefundTail = "على بطاقة بنك دبي الإسلامي الخاصة بك والمنتهية بالرقم"
	smsOwn        = "تحويل بين حساباتك بمبلغ"
	smsFromAcc    = "من حساب"
	smsToAcc      = "الي حساب"
	smsOwnTail    = "رصيد حساب الخصم هو AED 9,876.54 وحساب الايداع هو AED 8,765.43"
	smsCardPaid   = "تم سداد مبلغ"
	smsYourCard   = "لبطاقتك المنتهية"
	smsLimitWord  = "الحد الائتماني المتاح"
)

func sms(parts ...string) string { return strings.Join(parts, " ") }

func smsOwnTransfer(ccy string) string {
	amount := "4,321.09"
	if ccy != "" {
		amount = ccy + " " + amount
	}
	return sms(smsOwn, amount, smsFromAcc, "001-000-123XXXX-01", smsToAcc, "001-000-456XXXX-01", "في",
		"05-06-2026", "MB Fund Transfer", smsOwnTail)
}

func syntheticDIBSMS(t *testing.T) []syntheticGroup {
	t.Helper()
	group := func(family string, cases []syntheticCase) syntheticGroup {
		id := "dib.sms." + family + ".v1"
		return syntheticGroup{file: "sms/synthetic-dib-sms-" + family + ".json", template: id, definition: readSeed(t, id+".json"), cases: cases}
	}
	return []syntheticGroup{
		group("purchase", []syntheticCase{
			{"credit-card", "a credit card purchase: the card's last four, the merchant up to the limit sentence, a timed date", "",
				sms(smsPurchase, "123.45", smsCard, "XX1234", "في", "05-06-2026 10:11", "من", "SAMPLE SHOP"+smsLimit, "1,234.56")},
			{"debit-card", "an account purchase: no card number, the merchant up to the balance", "",
				sms(smsPurchase, "23.45", "في", "05-06-2026 11:22", "من", "SAMPLE CAFE", smsBalanceY, "2,345.67")},
			{"foreign-currency", "a currency code before the amount wins over AED", "",
				sms(smsPurchase, "USD 7.89", "في", "05-06-2026 12:33", "من", "EXAMPLE.COM", smsBalanceY, "2,345.67")},
			{"aed-prefix-card", "the newer wording writes AED before the amount", "",
				sms(smsPurchase, "AED 34.56", smsCard, "XX1234", "في", "05-06-2026 13:44", "من", "SAMPLE STORE"+smsLimit, "3,456.78")},
			{"merchant-ending-in-a-dot", "a merchant that ends in a dot keeps it", "",
				sms(smsPurchase, "45.67", smsCard, "XX1234", "في", "05-06-2026 10:01", "من", "EXAMPLE, INC."+smsLimit, "4,567.89")},
			{"thousands", "the [0-9,]{0,24} run", "",
				sms(smsPurchase, "12,345.67", "في", "05-06-2026 10:02", "من", "SAMPLE MOTORS", smsBalanceY, "5,678.90")},
			{"negative-limit", "an overdrawn card's limit is negative and is not read", "",
				sms(smsPurchase, "56.78", smsCard, "XX1234", "في", "05-06-2026 10:03", "من", "SAMPLE TELECOM"+smsLimit, "-12.34")},
			{"merchant-with-the-preposition", "the merchant runs from the time to the balance, whatever words it holds", "",
				sms(smsPurchase, "67.89", "في", "05-06-2026 10:04", "من", "AL SAMPLE", "من", "DUBAI", smsBalanceY, "6,789.01")},
			{"no-merchant", "an empty merchant leaves the field unset; the row still reads", "",
				sms(smsPurchase, "78.12", "في", "05-06-2026 10:05", "من", smsBalanceY, "7,890.12")},
			{"one-digit-hour", "one hour digit: the date, its time and the merchant still read", "",
				sms(smsPurchase, "89.01", "في", "05-06-2026 9:06", "من", "SAMPLE CAFE", smsBalanceY, "8,901.23")},
			{"one-digit-hour-card", "one hour digit on a card purchase: the merchant up to the limit sentence still reads", "",
				sms(smsPurchase, "90.12", smsCard, "XX1234", "في", "05-06-2026 8:07", "من", "SAMPLE BAKERY"+smsLimit, "9,123.45")},
			{"non-two-decimal-currency", "JPY has exponent 0: the amount is refused", "",
				sms(smsPurchase, "JPY 1,234.00", "في", "05-06-2026 10:07", "من", "SAMPLE JAPAN", smsBalanceY, "9,012.34")},
			{"three-decimals", "a third decimal is not an amount", "",
				sms(smsPurchase, "12.345", "في", "05-06-2026 10:08", "من", "SAMPLE", smsBalanceY, "1,111.11")},
			{"not-at-the-start", "the family phrase must open the text", "",
				"تنبيه: " + sms(smsPurchase, "12.34", "في", "05-06-2026 10:09", "من", "SAMPLE", smsBalanceY, "2,222.22")},
			{"one-time-password", "a purchase code text names an amount and is not a payment", "",
				sms("123456", "هو OTP للمشتريات من", "SAMPLE SHOP", smsBimablagh, "12.34 AED", "على بطاقتك", "1234")},
		}),
		group("debit", []syntheticCase{
			{"transfer", "an account debit whose description names a transfer", "",
				sms(smsDebit, "1,234.56", "في", "05-06-2026", "MB FUND TRANSFER DEBIT", smsBalance, "3,333.33")},
			{"bimablagh", "the bimablagh wording, and a balance glued to its word", "",
				sms(smsDebit, smsBimablagh, "234.56", "في", "05-06-2026", "OUTGOING DOMESTIC FUND TR", smsBalanceA+"4,444.44")},
			{"fee", "a charge is a debit and not a transfer", "",
				sms(smsDebit, "3.45", "في", "05-06-2026", "CASH MGMT. SERVICE CHARGES", smsBalance, "5,555.55")},
			{"lower-case-transfer", "the transfer flag folds ASCII case", "",
				sms(smsDebit, "456.78", "في", "05-06-2026", "MB Fund Transfer Debit", smsBalance, "6,666.66")},
			{"card-payment-from-account", "paying the DIB credit card from the account moves money to the person's own card", "",
				sms(smsDebit, smsBimablagh, "2,345.67", "في", "05-06-2026", smsCardPay1, smsBalanceY, "7,777.77")},
			{"card-payment-second-wording", "the other card payment wording", "",
				sms("تم", smsDebit, smsMablagh, "3,456.78", "في", "05-06-2026", smsCardPay2, smsBalanceY, "8,888.88")},
			{"international-atm", "an international cash withdrawal: a constant merchant, the date without its time", "",
				sms(smsATM, "567.89", "في", "05-06-2026 10:11", smsBalanceY, "9,999.99")},
			{"no-year", "a debit dated with no year is undated, so the receive time applies", "",
				sms("تم", smsDebit, "4,321.09", "من حسابك", "1234**567", "بتاريخ", "05-06", "SAMPLE DEBIT")},
			{"foreign-currency", "a currency code before the amount", "",
				sms(smsDebit, "USD 6.78", "في", "05-06-2026", "SAMPLE FEE", smsBalance, "1,212.12")},
			{"service-notice", "a notice that only mentions debiting is gated out", "",
				"عزيزي المتعامل، بعض المعاملات التي تمت على بطاقتك للخصم من بنك دبي الإسلامي."},
			{"discount-promotion", "the word for a debit is also the word for a discount; the amount pattern refuses it", "",
				sms("احصل على", smsDebit, "20%", "على SAMPLE")},
			{"own-transfer", "a transfer between the person's accounts belongs to its own template", "", smsOwnTransfer("AED")},
		}),
		group("credit", []syntheticCase{
			{"transfer", "an incoming transfer", "",
				sms(smsCredit, "987.65", "في", "05-06-2026", "INWARD UAE FUNDS TRANSFER", smsBalance, "2,121.21")},
			{"bimablagh", "the bimablagh wording", "",
				sms(smsCredit, smsBimablagh, "8,765.43", "في", "05-06-2026", "MB FUND TRANSFER CREDIT", smsBalanceA+"3,131.31")},
			{"hamza", "the spelling with a hamza", "",
				sms(smsCreditH, smsBimablagh, "76.54", "في", "05-06-2026", "REFUND", smsBalanceA, "4,141.41")},
			{"reference-in-description", "a description with a reference is kept whole", "",
				sms(smsCredit, "65.43", "في", "05-06-2026", "SAMPLE PURPOSE-DIBFTS : [1234567", smsBalance, "5,151.51")},
			{"own-account", "an own-account credit is a transfer", "",
				sms(smsCredit, "5,432.10", "في", "05-06-2026", "OWN ACCOUNT TRNSFER", smsBalance, "6,161.61")},
			{"salary", "a salary credit belongs to its own template", "",
				sms(smsCreditH, smsSalary, "05-06-2026", "-", smsMablagh, "12,345.67", smsBalance, "7,171.71")},
			{"own-transfer", "an own transfer names a credit account and belongs to its own template", "", smsOwnTransfer("AED")},
		}),
		group("salary", []syntheticCase{
			{"date-first", "the salary notice with its date first", "",
				sms(smsCreditH, smsSalary, "05-06-2026", "-", smsMablagh, "12,345.67", smsBalance, "8,181.81")},
			{"older-wording", "the older wording, in dirhams", "",
				sms("تم", smsCredit, smsSalary, smsMonth, "05-06-2026-", smsBimablagh, "12,345.67", smsDirham+".", smsBalanceA, "9,191.91")},
			{"other-currency-word", "only dirhams are read in the older wording", "",
				sms("تم", smsCredit, smsSalary, smsMonth, "05-06-2026-", smsBimablagh, "12,345.67", smsDollar+".", smsBalanceA, "1,010.10")},
			{"no-amount", "a salary text with no amount is missing its amount", "",
				sms(smsCreditH, smsSalary, "05-06-2026", smsBalance, "2,020.20")},
		}),
		group("refund", []syntheticCase{
			{"refund", "an amount returned to a card: a credit with the card's last four", "",
				sms(smsRefund, "123.45", smsDirham, smsRefundTail, "XX1234.")},
			{"thousands", "the [0-9,]{0,24} run", "", sms(smsRefund, "1,234.56", smsDirham, smsRefundTail, "XX1234.")},
			{"other-currency-word", "only dirhams are read", "", sms(smsRefund, "12.34", smsDollar, smsRefundTail, "XX1234.")},
			{"no-card", "the card is optional", "", sms(smsRefund, "23.45", smsDirham, "على بطاقة بنك دبي الإسلامي الخاصة بك.")},
		}),
		group("reversal", []syntheticCase{
			{"reversal", "a reversed card transaction: a credit with the merchant and card", "",
				"A transaction to the value of AED 34.56 made at SAMPLE SHOP on your DIB card ending with XX1234 has been reversed."},
			{"foreign-currency", "the currency code wins over AED", "",
				"A transaction to the value of USD 45.67 made at EXAMPLE.COM on your DIB card ending with XX1234 has been reversed."},
			{"not-reversed", "a transaction that was not reversed is gated out", "",
				"A transaction to the value of AED 34.56 made at SAMPLE SHOP on your DIB card ending with XX1234 has been approved."},
		}),
		group("own-transfer", []syntheticCase{
			{"own-transfer", "a transfer between the person's own accounts: a debit and a transfer; an account mask is no card, so no last four", "",
				smsOwnTransfer("AED")},
			{"no-currency", "without a code AED applies", "", smsOwnTransfer("")},
		}),
		group("card-payment", []syntheticCase{
			{"card-payment", "a payment received on the card: a credit, a transfer, a timed date", "",
				sms(smsCardPaid, "4,321.09", smsYourCard, "بــ", "1234", "في", ".05-06-2026 10:11", smsLimitWord, "5,432.10")},
			{"no-dot-before-the-date", "the dot before the date is optional", "",
				sms(smsCardPaid, "3,210.98", smsYourCard, "بــ", "1234", "في", "05-06-2026 11:22", smsLimitWord, "6,543.21")},
			{"one-tatweel", "the tatweel run after the preposition is bounded, not fixed", "",
				sms(smsCardPaid, "2,109.87", smsYourCard, "بـ", "1234", "في", ".05-06-2026 12:33", smsLimitWord, "7,654.32")},
			{"one-digit-hour", "one hour digit: the date and its time still read", "",
				sms(smsCardPaid, "1,098.76", smsYourCard, "بــ", "1234", "في", ".05-06-2026 7:44", smsLimitWord, "8,765.43")},
		}),
	}
}

func syntheticSMSDates() syntheticGroup {
	def := `{
	  "id":"synth.sms-dates","version":1,"bank":"t","channel":"sms","normalizer_version":1,
	  "match":{"sms_sender":["TEST-SMS"]},
	  "default_currency":"AED","date_from":"received",
	  "extract":[
	    {"field":"amount","type":"amount","source":"body","patterns":["Amt: (?P<amt>[^\\n]+)"]},
	    {"field":"direction","type":"const","source":"body","value":"debit"},
	    {"field":"date","type":"date","source":"body","layouts":["DD-MM-YYYY HH:mm","DD-MM-YYYY"],
	     "patterns":["Date: (?P<d>[^\\n]+)"]}
	  ],
	  "required":["amount","direction"]}`
	g := syntheticGroup{file: "sms/synthetic-sms-dates.json", template: "synth.sms-dates", definition: def}
	for _, c := range []struct{ name, date, why string }{
		{"timed", "05-06-2026 14:30", "the timed layout, whole string"},
		{"midnight", "05-06-2026 00:00", "a timed midnight"},
		{"last-minute", "05-06-2026 23:59", "the last minute of the day"},
		{"one-digit-hour", "05-06-2026 8:05", "Go's 15 accepts one hour digit"},
		{"hour-24", "05-06-2026 24:00", "hour 24 is out of range; the date-only layout reads the first token"},
		{"minute-60", "05-06-2026 12:60", "minute 60 is out of range; the first token still reads"},
		{"one-minute-digit", "05-06-2026 12:5", "the minute needs two digits"},
		{"three-hour-digits", "05-06-2026 123:45", "three hour digits leave trailing text"},
		{"date-only", "05-06-2026", "no time: the second layout"},
		{"trailing-text", "05-06-2026 14:30 extra", "trailing text: only the first token reads, as a date"},
		{"two-spaces", "05-06-2026  14:30", "two spaces: no whole-string attempt"},
		{"t-separator", "05-06-2026T14:30", "the separator is one U+0020"},
		{"leap-day", "29-02-2028 06:00", "a leap day"},
		{"not-a-leap-day", "29-02-2026 06:00", "calendar ranges are checked"},
	} {
		g.cases = append(g.cases, syntheticCase{c.name, c.why, "", "Amt: 1.00\nDate: " + c.date})
	}
	g.cases = append(g.cases, syntheticCase{"undated", "no date in the text: matched, and the receive time applies", "", "Amt: 1.00"})
	return g
}
