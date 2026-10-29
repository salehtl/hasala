#if HASALA_MOCKS
  import HasalaModels

  /// The "Earlier" list of Home · Notifications (11Y9-0) for the Maya mock: three things Hasala
  /// told Maya before, read and done. Synthetic, like the rest of her month. Debug only: a
  /// Release build keeps no notification history, so it shows "Needs a look" alone (plan B7.6,
  /// decision 12).
  struct MockNotificationFeed: NotificationFeed {
    func earlier(now: LocalDateTime) -> [NotificationItem] {
      [
        NotificationItem(
          id: "earlier.groceries", disc: .hue(.sand, .groceries), title: "Groceries is running fast",
          line: MoneyPhrase([
            .amount(.aed(812_40), hidden: 3), .text(" of "), .amount(.aed(2_200_00), .rounded, hidden: 3),
            .text(" so far. At this pace October ends near "), .amount(.aed(2_518_00), .rounded, hidden: 3),
            .text("."),
          ]),
          when: "9:12", destination: .category("groceries")),
        NotificationItem(
          id: "earlier.dib", disc: .neutral(.envelope), title: "No alerts from DIB for 3 days",
          line: "Fixed. Alerts are coming in again.", status: .success, when: "Tue", destination: .bankAlerts),
        NotificationItem(
          id: "earlier.rent", disc: .hue(.sand, .rent), title: "Rent is due Thu",
          line: MoneyPhrase([.amount(.aed(7_500_00), hidden: 3), .text(" from Emirates NBD. Paid 1 Oct.")]),
          when: NotificationsEngine.when(LocalDate(2026, 9, 28), today: now.date), destination: .bill("rent")),
      ]
    }
  }
#endif
