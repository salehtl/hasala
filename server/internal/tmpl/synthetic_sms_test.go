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
			{"international-atm", "an international cash withdrawal: a constant merchant, the date with its time", "",
				sms(smsATM, "567.89", "في", "05-06-2026 10:11", smsBalanceY, "9,999.99")},
			{"international-atm-one-digit-hour", "one hour digit on a cash withdrawal: the date keeps its time", "",
				sms(smsATM, "678.90", "في", "05-06-2026 7:08", smsBalanceY, "9,898.98")},
			{"international-atm-bad-time", "a time out of range falls back to the bare date", "",
				sms(smsATM, "789.01", "في", "05-06-2026 25:61", smsBalanceY, "9,797.97")},
			{"no-year", "a debit dated with no year is undated, so the receive time applies", "",
				sms("تم", smsDebit, "4,321.09", "من حسابك", "1234**567", "بتاريخ", "05-06", "SAMPLE DEBIT")},
			{"dated-with-year", "the same debit dated with a year reads its date", "",
				sms("تم", smsDebit, "3,210.98", "من حسابك", "1234**567", "بتاريخ", "05-06-2026", "SAMPLE DEBIT")},
			{"dated-with-year-transfer", "a dated debit whose description names a transfer", "",
				sms("تم", smsDebit, "2,109.87", "من حسابك", "1234**567", "بتاريخ", "07-08-2026", "SAMPLE FUND TRANSFER")},
			{"dated-bad-day", "a day out of range on the dated debit leaves the row undated", "",
				sms("تم", smsDebit, "1,098.76", "من حسابك", "1234**567", "بتاريخ", "31-02-2026", "SAMPLE DEBIT")},
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

func syntheticENBDSMS(t *testing.T) []syntheticGroup {
	t.Helper()
	group := func(family string, cases []syntheticCase) syntheticGroup {
		id := "enbd.sms." + family + ".v1"
		return syntheticGroup{file: "sms/synthetic-enbd-sms-" + family + ".json", template: id, definition: readSeed(t, id+".json"), cases: cases}
	}
	return []syntheticGroup{
		group("bill-payment", []syntheticCase{
			{"bill-payment", "a credit card bill payment: the biller, the card's last four, the statement note glued to the card", "",
				"Bill Pymt for SAMPLE STREAMING of AED 56.78 has been made using Credit Card 1234.Refer stmt for exact amount."},
			{"no-statement-note", "the statement note is optional", "",
				"Bill Pymt for SAMPLE TELECOM-E of AED 123.45 has been made using Credit Card 1234."},
			{"foreign-currency", "a currency code other than AED", "",
				"Bill Pymt for EXAMPLE HOSTING of USD 12.34 has been made using Credit Card 5678.Refer stmt for exact amount."},
			{"biller-with-of", "a biller whose name holds the word of keeps it", "",
				"Bill Pymt for HOUSE of SAMPLE of AED 99.00 has been made using Credit Card 1234."},
			{"whole-amount", "an amount with no decimals is not an amount, so the text is missing its amount", "",
				"Bill Pymt for SAMPLE TV of USD 100 has been made using Credit Card 1234."},
		}),
		group("card-purchase", []syntheticCase{
			{"debit-card", "a debit card purchase: the merchant up to the first comma, the card's last four", "",
				"Purchase of AED 45.67 with Debit Card ending 1234 at SAMPLE CAFE, DUBAI. Avl Balance is AED 1,234.56."},
			{"no-city", "a merchant with no city runs up to the balance", "",
				"Purchase of AED 12.30 with Debit Card ending 1234 at SAMPLE STORE. Avl Balance is AED 2,345.67."},
			{"foreign-currency", "a foreign currency purchase and the statement note", "",
				"Purchase of USD 20.00 with Debit Card ending 1234 at EXAMPLE.COM, +12345678. Avl Balance is AED 3,456.78. Pls refer stmt for exact amt."},
			{"two-commas", "the merchant stops at the first comma", "",
				"Purchase of AED 1,234.50 with Debit Card ending 5678 at SAMPLE MART, SAMPLE CITY, AREA. Avl Balance is AED 4,567.89."},
			{"merchant-ending-in-a-dot", "a merchant that ends in a dot keeps it", "",
				"Purchase of AED 34.00 with Debit Card ending 1234 at SAMPLE ST., CITY. Avl Balance is AED 5,678.90."},
			{"three-decimals", "a third decimal is not an amount", "",
				"Purchase of AED 12.345 with Debit Card ending 1234 at SAMPLE CAFE, DUBAI. Avl Balance is AED 1,234.56."},
			{"refund", "a refunded purchase belongs to the refund template", "",
				"Purchase amount of AED 45.67 at SAMPLE CAFE on your Debit Card ending 1234 has been refunded to your card account. Avl Bal is AED 1,234.56."},
		}),
		group("cash-withdrawal", []syntheticCase{
			{"atm", "a cash withdrawal: a constant merchant and the card's last four", "",
				"Cash Withdrawal of AED 517.36 with Debit Card ending 1234 at SAMPLE MALL, DUBAI. Avl Bal is AED 6,789.01."},
			{"no-comma", "an ATM location with no comma", "",
				"Cash Withdrawal of AED 1,013.27 with Debit Card ending 1234 at SAMPLE STATION 2 DUBAI. Avl Bal is AED 7,890.12."},
			{"purchase", "a card purchase belongs to its own template", "",
				"Purchase of AED 45.67 with Debit Card ending 1234 at SAMPLE CAFE, DUBAI. Avl Balance is AED 1,234.56."},
		}),
		group("cheque-deposit", []syntheticCase{
			{"cheque", "a cleared cheque: a credit dated by the text", "",
				"Dear Customer, the cheque number 000123 for AED 2,531.46 has been deposited to account 101-XXX23XXX-01 on 05-06-2026 10:11:12 AM.Available Balance AED 9,876.54"},
			{"no-greeting", "the greeting is optional", "",
				"the cheque number 000124 for AED 253.18 has been deposited to account 101-XXX23XXX-01 on 07-08-2026 03:04:05 PM.Available Balance AED 9,000.00"},
			{"bad-day", "a day out of range leaves the row undated", "",
				"Dear Customer, the cheque number 000125 for AED 25.00 has been deposited to account 101-XXX23XXX-01 on 31-02-2026 10:11:12 AM.Available Balance AED 9,025.00"},
			{"deposit-machine", "cheques put in a deposit machine name no amount and are not a payment", "",
				"2 cheque(s) has been deposited to your account 101XXX23XXX01 through the deposit machine. Deposit to be confirmed after successful cheque clearing."},
		}),
		group("credit", []syntheticCase{
			{"account-credit", "an account credit with no description: no merchant", "",
				"AED 1,517.29 has been credited to account 101XXX23XXX01. Current balance is AED 2,531.46. Credits post cut-offs will be available next day."},
			{"instant-transfer", "an instant transfer received, after a greeting", "",
				"Dear Customer, AED 253.18 has been credited to your account 101XXX23XXX01 towards instant transfer. The available balance is AED 3,000.00."},
			{"inward-transfer", "an inward telegraphic transfer: a constant merchant in place of the sender", "",
				"AED 4,028.67 has been credited to your account no. 101XXX23XXX01 IPI TT REF: SAMPLE SENDER /REF/M. The available balance is AED 7,031.55."},
			{"dtb-transfer", "the DTB transfer wording", "",
				"AED 300.00 has been credited to your account no. 101XXX23XXX01 DTB TR REF SAMPLEREF0001 1234 BY D. The available balance is AED 7,300.00."},
			{"global-equities", "money back from the person's own brokerage account is a transfer", "",
				"USD 1,013.27 has been credited to your account no. 101XXX23XXX02 MOBILE WTH GL EQ 12345/678901 REF.-1A2B3C. The available balance is USD 1,517.29."},
			{"mobile-transfer", "a mobile banking transfer between the person's accounts is a transfer", "",
				"USD 207.53 has been credited to your account no. 101XXX23XXX02 MOBILE TRF-1A2B3C4D. The available balance is USD 1,700.00."},
			{"described", "another description is the merchant", "",
				"AED 75.00 has been credited to your account no. 101XXX23XXX01 SAMPLE CREDIT REF. 1234. The available balance is AED 7,106.73."},
			{"sb-reference", "a credit described only by an SB reference: a constant merchant in place of the reference", "",
				"AED 1,250.00 has been credited to your account no. 101XXX23XXX01 SB REF. 12345678. The available balance is AED 8,356.73."},
			{"transferred", "money transferred in belongs to its own template", "",
				"AED 517.36 has been transferred to your account 101XXX23XXX01"},
		}),
		group("credit-card-purchase", []syntheticCase{
			{"purchase", "a credit card purchase: the merchant up to the first comma, the card's last four", "",
				"You made a purchase of AED 89.50 at SAMPLE GROCERY, DUBAI with your Credit Card ending 5678."},
			{"no-comma", "a merchant and city with no comma run up to the card", "",
				"You made a purchase of AED 42.00 at SAMPLE BAKERY 12 SAMPLE CITY with your Credit Card ending 5678."},
			{"statement-note", "the statement note after the card", "",
				"You made a purchase of AED 610.25 at SAMPLE RENTALS, SAMPLE CITY with your Credit Card ending 5678. Refer stmt for exact amount."},
			{"foreign-currency", "a currency code other than AED", "",
				"You made a purchase of USD 25.99 at EXAMPLE TV, SAMPLE CITY with your Credit Card ending 5678. Refer stmt for exact amount."},
			{"whole-amount", "an amount with no decimals is not an amount, so the text is missing its amount", "",
				"You made a purchase of USD 999 at EXAMPLE TV, SAMPLE CITY with your Credit Card ending 5678. Refer stmt for exact amount."},
			{"instalment-offer", "an instalment offer names a purchase and is not a payment", "",
				"*Convert now* Pay as low as AED 50.00 per month for the purchase of AED 600.00 at SAMPLE AIR with credit card ending 5678 via clicking https://example.com/ipp"},
			{"auth-code", "a purchase code names an amount and is not a payment", "",
				"DO NOT SHARE! The Auth code is 123456 for AED 89.50 at SAMPLE AIR for card ending 5678. Use in 5 mins."},
		}),
		group("debit", []syntheticCase{
			{"telegraphic-transfer", "a telegraphic transfer paid from the account: a constant merchant, not an own transfer", "",
				"AED 12,345.00 has been deducted from your account 101XXX23XXX01 for issuance of Telegraphic Transfer. The available balance is AED 1,013.27."},
			{"telegraphic-transfer-no-balance", "the balance is optional", "",
				"USD 2,047.19 has been deducted from your account 101XXX23XXX02 for issuance of Telegraphic Transfer."},
			{"directremit", "the DirectRemit wording", "",
				"AED 3,000.00 has been deducted from your account 101XXX23XXX01 for issuance of DirectRemit. The available balance is AED 2,047.19."},
			{"online-transfer-named", "an online transfer after a greeting with a name", "",
				"Dear Sample Person, AED 4,537.92 has been deducted from your account 2301 for Fund Transfer through Online Banking."},
			{"online-transfer-customer", "an online transfer after the generic greeting", "",
				"Dear Customer, AED 450.00 has been deducted from your account 2301 for Fund Transfer through Online Banking."},
			{"global-equities", "money sent to the person's own brokerage account is a transfer", "",
				"AED 10,041.63 has been debited from your account no. 101XXX23XXX01 MOBILE TRF TO GL EQ 12345/678901 REF-1A2B3C4D5E6F. The available balance is AED 517.36."},
			{"mobile-transfer", "a mobile banking transfer between the person's accounts is a transfer", "",
				"USD 1,517.29 has been debited from your account no. 101XXX23XXX02 MOBILE TRF-1A2B3C4D. The available balance is USD 103.71."},
			{"correspondent-charges", "a transfer charge is a debit and not a transfer", "",
				"AED 55.00 has been debited from your account no. 101XXX23XXX01 RMA TT CORR CHARGES SAMPLEREF0001 USD 15@3.673. The available balance is AED 445.00."},
			{"branch-withdrawal", "cash taken from the account is a cash withdrawal", "",
				"AED 20,064.38 has been withdrawn from your account 101XXX23XXX01. The available balance is AED 5,019.84. Save queuing time by using our free ATMs 24 x 7."},
			{"described", "another description is the merchant", "",
				"AED 12.00 has been debited from your account no. 101XXX23XXX01 SAMPLE FEE. The available balance is AED 433.00."},
			{"brokerage-notice", "a brokerage account notice is not an account debit", "",
				"USD 1,013.2 has been withdrawn successfully from your USD Global Equities 12345/678901."},
			{"standing-instruction", "setting up a standing instruction moves no money", "",
				"Dear Customer, You have set up a Standing Instruction through Online/Mobile Banking for Local UAEFTS transfer to SAMPLE PAYEE from your Account 101***23***01 with amount of AED 517.36. Your Reference number is 123."},
		}),
		group("funds-transfer", []syntheticCase{
			{"wallet", "a transfer paid with the debit card to a wallet: the payee, the card's last four, a transfer", "",
				"Funds Transfer of AED 300.00 has been made using your Debit Card ending 1234 at SAMPLE WALLET. Your current balance is AED 1,216.43."},
			{"thousands", "the [0-9,]{0,24} run", "",
				"Funds Transfer of AED 1,263.81 has been made using your Debit Card ending 1234 at SAMPLE WALLET. Your current balance is AED 950.00."},
		}),
		group("refund", []syntheticCase{
			{"refund", "a refunded card purchase: a credit with the merchant and the card's last four", "",
				"Purchase amount of AED 45.67 at SAMPLE CAFE on your Debit Card ending 1234 has been refunded to your card account. Avl Bal is AED 1,234.56."},
			{"foreign-currency", "a currency code other than AED", "",
				"Purchase amount of USD 9.99 at EXAMPLE.COM on your Debit Card ending 1234 has been refunded to your card account. Avl Bal is AED 1,271.25."},
		}),
		group("transfer-in", []syntheticCase{
			{"transfer-in", "money transferred into the account: a credit and a transfer", "",
				"AED 517.36 has been transferred to your account 101XXX23XXX01"},
			{"with-balance", "the balance is optional", "",
				"USD 253.18 has been transferred to your account 101XXX23XXX02. The available balance is USD 300.00."},
			{"credited", "a credit belongs to the credit template", "",
				"AED 1.07 has been credited to your account 101XXX23XXX01 towards instant transfer. The available balance is AED 3,004.62."},
		}),
	}
}
