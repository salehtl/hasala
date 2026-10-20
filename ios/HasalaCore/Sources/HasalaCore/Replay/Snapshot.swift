// The fold fingerprint canary (replay/snapshot.ts `CANARY`, extended for v4 as
// spec 03c §11 asks) and the Codable fold snapshot (spec 04 §5.3).
//
// `foldPrint` is the first 32 lower-case hex digits of
// SHA-256(serializeState(fold(canary))). Any change to fold semantics changes
// it, which invalidates every saved snapshot (a cold fold rebuilds). The v3
// half of the canary is conformance/replay's `canary-canary-v3` log, byte for
// byte (a conformance test pins the copy); the v4 half has one op of every v4
// type, a keyed overwrite whose later position carries an older
// `authored_at`, an annotation forward through a supersede, an un-split, a
// held bulk, goals with a category and an `ac_cash` source, and a mailbox
// retirement that takes a new-format row and a legacy row's successor, a
// certain copy whose verified sender wins and takes the earlier copy's sort, a
// probable copy kept as its own row, and a bank's transfer notice whose debit
// alert is held as its copy.
//
// The snapshot is a binary property list of `StateSnapshot`. Ordered maps
// encode their insertion order, so a warm start projects the same `ord`
// columns as a cold fold (client-core-b §5.4's TypeScript bug is not
// ported). The validation table (`bound_tip`, digest, cursor) belongs to the
// store that keeps the row (CoreStore, spec 04 §5.3).
import CoreJSON
import CorePrimitives
import CoreWire
import Foundation

public enum FoldCanary {
  /// One JSON object per line: `{"seq", "writer_id", "ops": [...]}`.
  static let text = """
{"seq":"1","writer_id":"dev-a","ops":[{"v":1,"type":"home_currency_set","op_id":"canary-01","authored_at":"2020-01-02T01:00:00.000Z","parent_version":null,"payload":{"currency":"AED"}}]}
{"seq":"2","writer_id":"dev-a","ops":[{"v":1,"type":"rate_set","op_id":"canary-02","authored_at":"2020-01-03T02:00:00.000Z","parent_version":null,"payload":{"currency":"USD","rate_micro":"3672500"}}]}
{"seq":"3","writer_id":"dev-a","ops":[{"v":1,"type":"rate_set","op_id":"canary-03","authored_at":"2020-01-04T03:00:00.000Z","parent_version":null,"payload":{"currency":"JPY","rate_micro":"24500"}}]}
{"seq":"4","writer_id":"dev-a","ops":[{"v":1,"type":"rate_unset","op_id":"canary-04","authored_at":"2020-01-05T04:00:00.000Z","parent_version":null,"payload":{"currency":"JPY"}}]}
{"seq":"5","writer_id":"ingest","ops":[{"v":1,"type":"txn_ingested","op_id":"canary-05","authored_at":"2020-01-06T05:00:00.000Z","entity":{"kind":"txn","id":"c1"},"parent_version":null,"ingest_id":"0000000000000000000000000000000000000000000000000000000000000001","payload":{"amount_minor":"1001","currency":"AED","direction":"credit","posted_at":"2020-01-02T12:00:00Z","merchant_raw":"CANARY MERCHANT 1","last4":"1001","needs_review":false,"tier":"heuristic"}}]}
{"seq":"6","writer_id":"ingest","ops":[{"v":1,"type":"txn_ingested","op_id":"canary-06","authored_at":"2020-01-07T06:00:00.000Z","entity":{"kind":"txn","id":"c2"},"parent_version":null,"ingest_id":"0000000000000000000000000000000000000000000000000000000000000002","payload":{"amount_minor":"1002","currency":"AED","direction":"debit","posted_at":"2020-01-03T12:00:00Z","merchant_raw":"CANARY MERCHANT 2","last4":"1002","needs_review":true,"tier":"template"}}]}
{"seq":"7","writer_id":"ingest","ops":[{"v":1,"type":"txn_ingested","op_id":"canary-07","authored_at":"2020-01-08T07:00:00.000Z","entity":{"kind":"txn","id":"c3"},"parent_version":null,"ingest_id":"0000000000000000000000000000000000000000000000000000000000000003","payload":{"amount_minor":"1003","currency":"GBP","direction":"credit","posted_at":"2020-01-04T12:00:00Z","merchant_raw":"CANARY MERCHANT 3","last4":"1003","needs_review":false,"tier":"heuristic"}}]}
{"seq":"8","writer_id":"ingest","ops":[{"v":1,"type":"txn_ingested","op_id":"canary-08","authored_at":"2020-01-09T08:00:00.000Z","entity":{"kind":"txn","id":"c4"},"parent_version":null,"ingest_id":"0000000000000000000000000000000000000000000000000000000000000004","payload":{"amount_minor":"0","currency":"","direction":"","posted_at":"2020-01-05T00:00:00Z","merchant_raw":"","last4":"","tier":"none","needs_review":true,"unparsed":true}}]}
{"seq":"9","writer_id":"dev-a","ops":[{"v":1,"type":"txn_categorized","op_id":"canary-09","authored_at":"2020-01-01T00:00:00.000Z","entity":{"kind":"txn","id":"c1"},"parent_version":1,"payload":{"category":"groceries"}}]}
{"seq":"10","writer_id":"dev-a","ops":[{"v":1,"type":"txn_split","op_id":"canary-10","authored_at":"2020-01-02T01:00:00.000Z","entity":{"kind":"txn","id":"c1"},"parent_version":2,"payload":{"parts":[{"category":"food","amount_minor":"600"},{"category":"household","amount_minor":"401"}]}}]}
{"seq":"11","writer_id":"dev-b","ops":[{"v":1,"type":"txn_edited","op_id":"canary-11","authored_at":"2020-01-03T02:00:00.000Z","entity":{"kind":"txn","id":"c2"},"parent_version":1,"payload":{"merchant_raw":"CANARY EDITED"}}]}
{"seq":"12","writer_id":"dev-a","ops":[{"v":1,"type":"txn_categorized","op_id":"canary-12","authored_at":"2020-01-04T03:00:00.000Z","entity":{"kind":"txn","id":"c3"},"parent_version":1,"payload":{"category":"travel"}}]}
{"seq":"13","writer_id":"dev-b","ops":[{"v":1,"type":"txn_categorized","op_id":"canary-13","authored_at":"2020-01-05T04:00:00.000Z","entity":{"kind":"txn","id":"c3"},"parent_version":1,"payload":{"category":"transport"}}]}
{"seq":"14","writer_id":"ingest","ops":[{"v":1,"type":"txn_ingested","op_id":"canary-14","authored_at":"2020-01-06T05:00:00.000Z","entity":{"kind":"txn","id":"c5"},"parent_version":null,"ingest_id":"0000000000000000000000000000000000000000000000000000000000000001","payload":{"amount_minor":"1005","currency":"AED","direction":"credit","posted_at":"2020-01-06T12:00:00Z","merchant_raw":"CANARY MERCHANT 5","last4":"1005","needs_review":false,"tier":"heuristic"}}]}
{"seq":"15","writer_id":"ingest","ops":[{"v":1,"type":"txn_superseded","op_id":"canary-15","authored_at":"2020-01-07T06:00:00.000Z","entity":{"kind":"txn","id":"c6"},"parent_version":null,"ingest_id":"0000000000000000000000000000000000000000000000000000000000000002","payload":{"amount_minor":"1006","currency":"USD","direction":"debit","posted_at":"2020-01-07T12:00:00Z","merchant_raw":"CANARY MERCHANT 6","last4":"1006","needs_review":true,"tier":"template"}}]}
{"seq":"16","writer_id":"dev-a","ops":[{"v":1,"type":"rule_added","op_id":"canary-16","authored_at":"2020-01-08T07:00:00.000Z","entity":{"kind":"rule","id":"r1"},"parent_version":null,"payload":{"pattern":"CANARY","match":"contains","category":"misc","priority":10}}]}
{"seq":"17","writer_id":"dev-b","ops":[{"v":1,"type":"rule_added","op_id":"canary-17","authored_at":"2020-01-09T08:00:00.000Z","entity":{"kind":"rule","id":"r2"},"parent_version":null,"payload":{"pattern":"^CAN","match":"regex","category":"other","priority":90}}]}
{"seq":"18","writer_id":"dev-a","ops":[{"v":3,"type":"bank_declared","op_id":"canary-18","authored_at":"2020-01-01T00:00:00.000Z","parent_version":null,"payload":{"bank":"dib","active":true}}]}
{"seq":"19","writer_id":"dev-b","ops":[{"v":3,"type":"bank_declared","op_id":"canary-19","authored_at":"2020-01-02T01:00:00.000Z","parent_version":null,"payload":{"bank":"enbd","active":true}}]}
{"seq":"20","writer_id":"dev-a","ops":[{"v":3,"type":"bank_declared","op_id":"canary-20","authored_at":"2020-01-03T02:00:00.000Z","parent_version":null,"payload":{"bank":"enbd","active":false}}]}
{"seq":"21","writer_id":"dev-a","ops":[{"v":3,"type":"budget_split_set","op_id":"canary-21","authored_at":"2020-01-04T03:00:00.000Z","parent_version":null,"payload":{"need":60,"want":20,"saving":20}}]}
{"seq":"22","writer_id":"dev-b","ops":[{"v":3,"type":"budget_split_set","op_id":"canary-22","authored_at":"2020-01-05T04:00:00.000Z","parent_version":null,"payload":{"need":50,"want":30,"saving":20,"monthly_total_minor":"9007199254740993"}}]}
{"seq":"23","writer_id":"dev-a","ops":[{"v":3,"type":"category_defined","op_id":"canary-23","authored_at":"2020-01-06T05:00:00.000Z","parent_version":null,"payload":{"id":"k1","name":"Groceries","kind":"spending","bucket":"need","color":"#88aa66","active":true}}]}
{"seq":"24","writer_id":"dev-a","ops":[{"v":3,"type":"category_defined","op_id":"canary-24","authored_at":"2020-01-07T06:00:00.000Z","parent_version":null,"payload":{"id":"k1","name":"Food","kind":"spending","bucket":"want","color":"#88aa66","active":true}}]}
{"seq":"25","writer_id":"dev-b","ops":[{"v":3,"type":"category_defined","op_id":"canary-25","authored_at":"2020-01-08T07:00:00.000Z","parent_version":null,"payload":{"id":"k2","name":"Salary","kind":"income","bucket":null,"active":false}}]}
{"seq":"26","writer_id":"dev-a","ops":[{"v":1,"type":"writer_checkpoint","op_id":"canary-26","authored_at":"2020-01-09T08:00:00.000Z","parent_version":null,"payload":{"heads":[{"writer_id":"dev-a","stream":"hot","counter":"3","hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"writer_id":"ingest","stream":"hot","counter":"7","hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}}]}
{"seq":"27","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"category_defined","op_id":"canary-v4-01","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"id":"c_01jc0000000000000000000001","name":"Emergency fund","kind":"spending","bucket":"saving","icon":"jar","active":true}},{"v":4,"type":"sender_trust_set","op_id":"canary-v4-02","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"domain":"emiratesnbd.com","trusted":true}}]}
{"seq":"28","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_ingested","op_id":"canary-v4-03","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000001"},"parent_version":null,"ingest_id":"00000000000000000000000000000000000000000000000000000000000000a1","payload":{"amount_minor":"5000","currency":"AED","direction":"debit","posted_at":"2020-02-01T08:00:00.000Z","merchant_raw":"CARREFOUR MOE","last4":"4412","category":"groceries","category_source":{"kind":"dictionary","bundle":"2026.10.11-1","entry":"contains:carrefour"},"needs_review":false,"tier":"template","entry_method":"mailbox","bank":"enbd","posted_precision":"time","gates":{"ar":"pass","sender":"trusted","template":"enbd-card@1","card":"known","forwarded":false},"provenance":{"provider":"gmail","grant_id":"g1","message_id":"m1"}}},{"v":4,"type":"txn_ingested","op_id":"canary-v4-04","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000002"},"parent_version":null,"ingest_id":"00000000000000000000000000000000000000000000000000000000000000a2","payload":{"amount_minor":"12000","currency":"AED","direction":"debit","posted_at":"2020-02-02T08:00:00.000Z","merchant_raw":"IKEA","last4":"4412","category":null,"needs_review":true,"entry_method":"manual","location":"DIFC"}}]}
{"seq":"29","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"rule_added","op_id":"canary-v4-05","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"rule","id":"01JC0000000000000000000004"},"parent_version":null,"payload":{"patterns":["carrefour","spinneys"],"match":"contains","category":"groceries","priority":10,"enabled":true,"removed":false,"origin":"manual"}},{"v":4,"type":"txn_categorized","op_id":"canary-v4-06","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000001"},"parent_version":1,"payload":{"category":"groceries","needs_review":false,"source":{"kind":"rule","rule_id":"01JC0000000000000000000004"}}}]}
{"seq":"30","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_annotated","op_id":"canary-v4-07","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"txn_id":"01JC0000000000000000000001","set":{"note":"Weekly shop","project_id":"01JC0000000000000000000005","account_id":"ac_cash"}}},{"v":4,"type":"merchant_named","op_id":"canary-v4-08","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"merchant_key":"carrefour moe","display_name":"Carrefour"}}]}
{"seq":"31","writer_id":"ios-1b2c3d4e-5f60-4b7c-8d9e-0f1a2b3c4d5e","ops":[{"v":4,"type":"merchant_named","op_id":"canary-v4-09","authored_at":"2019-12-01T00:00:00.000Z","parent_version":null,"payload":{"merchant_key":"carrefour moe","display_name":"Carrefour MoE"}}]}
{"seq":"32","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_split","op_id":"canary-v4-10","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000001"},"parent_version":2,"payload":{"parts":[{"category":"groceries","amount_minor":"3000"},{"category":"shopping","amount_minor":"2000","note":"Towels"}]}}]}
{"seq":"33","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_split","op_id":"canary-v4-11","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000001"},"parent_version":3,"payload":{"parts":[]}}]}
{"seq":"34","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_superseded","op_id":"canary-v4-12","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000003"},"parent_version":null,"ingest_id":"00000000000000000000000000000000000000000000000000000000000000a1","payload":{"amount_minor":"5100","currency":"AED","direction":"debit","posted_at":"2020-02-01T08:00:00.000Z","merchant_raw":"CARREFOUR MOE","last4":"4412","category":"groceries","category_source":{"kind":"user"},"needs_review":false,"tier":"template"}}]}
{"seq":"35","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_annotated","op_id":"canary-v4-13","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"txn_id":"01JC0000000000000000000001","set":{"archived":"user"}}}]}
{"seq":"36","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"rule_added","op_id":"canary-v4-14","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"rule","id":"01JC0000000000000000000004"},"parent_version":1,"payload":{"patterns":["carrefour","spinneys"],"match":"contains","category":"groceries","priority":10,"enabled":false,"removed":false,"origin":"manual"}},{"v":4,"type":"txn_categorized","op_id":"canary-v4-15","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000003"},"parent_version":1,"payload":{"category":"groceries","needs_review":true,"source":{"kind":"held","rule_id":"01JC0000000000000000000004"}}}]}
{"seq":"37","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"project_defined","op_id":"canary-v4-16","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"project","id":"01JC0000000000000000000005"},"parent_version":null,"payload":{"name":"Japan trip","starts_on":"2026-12-14","ends_on":"2026-12-28","budget_minor":"1200000","count_in_plan":false,"status":"active","icon":"plane"}},{"v":4,"type":"goal_defined","op_id":"canary-v4-17","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"goal","id":"01JC0000000000000000000006"},"parent_version":null,"payload":{"name":"Emergency fund","target_minor":"5000000","target_month":"2027-01","source":{"kind":"category","category_id":"c_01jc0000000000000000000001","since":"2026-01-01"},"starting_minor":"3000000","status":"active","icon":"jar"}},{"v":4,"type":"goal_defined","op_id":"canary-v4-18","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"goal","id":"01JC0000000000000000000007"},"parent_version":null,"payload":{"name":"Cash buffer","target_minor":"100000","target_month":null,"source":{"kind":"account","account_id":"ac_cash"},"starting_minor":"0","status":"active","icon":null}}]}
{"seq":"38","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"budget_set","op_id":"canary-v4-19","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"category_id":"dining","month":"2026-10","amount_minor":"160000","scope":"onward"}},{"v":4,"type":"budget_moved","op_id":"canary-v4-20","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"month":"2026-10","from_category_id":null,"to_category_id":"groceries","amount_minor":"31800","reason":"move","batch_id":null,"undoes":null}},{"v":4,"type":"income_source_set","op_id":"canary-v4-21","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"id":"5b0f6c1e-4f8e-4a53-9a3e-2f6b8d1c7e10","name":"Salary","category_id":"salary","amount_minor":"2500000","payday":28,"active":true}},{"v":4,"type":"category_plan_role_set","op_id":"canary-v4-22","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"category_id":"subscriptions","role":"bills"}}]}
{"seq":"39","writer_id":"ios-1b2c3d4e-5f60-4b7c-8d9e-0f1a2b3c4d5e","ops":[{"v":4,"type":"budget_set","op_id":"canary-v4-23","authored_at":"2019-12-01T00:00:00.000Z","parent_version":null,"payload":{"category_id":"dining","month":"2026-10","amount_minor":"180000","scope":"only"}}]}
{"seq":"40","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"account_set","op_id":"canary-v4-24","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"id":"ac_cash","name":"Cash","institution":null,"kind":"cash","in_plan":true,"currency":"AED","statement_due_day":null,"active":true,"closed_on":null,"color":null}},{"v":4,"type":"card_linked","op_id":"canary-v4-25","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"bank":"enbd","last4":"4412","state":"mine","account":"ac_cash"}},{"v":4,"type":"account_checkin","op_id":"canary-v4-26","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"id":"ck_1","account":"ac_cash","as_of":"2026-10-10T09:31:20.000Z","balance_minor":"50000","source":"checkin","resolution":"kept","void":false}},{"v":4,"type":"bill_set","op_id":"canary-v4-27","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"bill","id":"bd_axa"},"parent_version":null,"payload":{"name":"AXA Insurance","keys":["axa insurance"],"direction":"debit","currency":"AED","amount_mode":"fixed","amount_minor":"55000","tolerance_bp":200,"cadence":{"unit":"month","every":1},"anchor":"2026-09-07","start":"2026-04-07","end":null,"category":"insurance","account":"ac_cash","source":"detected","status":"active"}},{"v":4,"type":"bill_occurrence_set","op_id":"canary-v4-28","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"bill":"bd_axa","due":"2026-10-07","resolution":"paid","txn":"01JC0000000000000000000002","until":null}}]}
{"seq":"41","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_ingested","op_id":"canary-v4-29","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000008"},"parent_version":null,"ingest_id":"00000000000000000000000000000000000000000000000000000000000000a8","payload":{"amount_minor":"2700","currency":"AED","direction":"debit","posted_at":"2020-02-03T08:00:00.000Z","merchant_raw":"CANARY CAFE","last4":"4412","category":null,"needs_review":true,"tier":"template","entry_method":"mailbox","bank":"enbd","posted_precision":"time","provenance":{"provider":"gmail","grant_id":"g1/mbx-00112233445566778899aabbccddeeff","message_id":"m8"}}}]}
{"seq":"42","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"mailbox_retired","op_id":"canary-v4-30","authored_at":"2020-02-01T00:00:00.000Z","parent_version":null,"payload":{"grant_id":"g1/mbx-00112233445566778899aabbccddeeff","provider":"gmail","legacy":true}}]}
{"seq":"43","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_ingested","op_id":"canary-v4-31","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000009"},"parent_version":null,"ingest_id":"00000000000000000000000000000000000000000000000000000000000000a9","payload":{"amount_minor":"2700","currency":"AED","direction":"debit","posted_at":"2020-02-04T08:00:00.000Z","merchant_raw":"CANARY COFFEE","last4":"4412","category":null,"needs_review":true,"tier":"template","entry_method":"mailbox","bank":"enbd","posted_precision":"time","gates":{"ar":"fail","sender":"untrusted","template":"enbd-card@1","card":"known","forwarded":false},"provenance":{"provider":"gmail","grant_id":"g2/mbx-00000000000000000000000000000009","message_id":"c09"},"dedupe":{"message_id":"00112233445566778899aabbccddeeff"}}},{"v":4,"type":"txn_categorized","op_id":"canary-v4-35","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000009"},"parent_version":1,"payload":{"category":"dining","needs_review":false,"source":{"kind":"user"}}},{"v":4,"type":"txn_ingested","op_id":"canary-v4-32","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000010"},"parent_version":null,"ingest_id":"00000000000000000000000000000000000000000000000000000000000000aa","payload":{"amount_minor":"2700","currency":"AED","direction":"debit","posted_at":"2020-02-04T08:00:00.000Z","merchant_raw":"CANARY COFFEE","last4":"4412","category":null,"needs_review":true,"tier":"template","entry_method":"mailbox","bank":"enbd","posted_precision":"time","gates":{"ar":"pass","sender":"trusted","template":"enbd-card@1","card":"known","forwarded":false},"provenance":{"provider":"gmail","grant_id":"g2/mbx-00000000000000000000000000000000","message_id":"c10"},"dedupe":{"message_id":"00112233445566778899aabbccddeeff"}}}]}
{"seq":"44","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_ingested","op_id":"canary-v4-33","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000011"},"parent_version":null,"ingest_id":"00000000000000000000000000000000000000000000000000000000000000ab","payload":{"amount_minor":"2700","currency":"AED","direction":"debit","posted_at":"2020-02-04T08:06:00.000Z","merchant_raw":"CANARY COFFEE","last4":"4412","category":null,"needs_review":true,"tier":"template","entry_method":"mailbox","bank":"enbd","posted_precision":"time","gates":{"ar":"fail","sender":"untrusted","template":"enbd-card@1","card":"known","forwarded":false},"provenance":{"provider":"gmail","grant_id":"g2/mbx-00000000000000000000000000000001","message_id":"c11"}}}]}
{"seq":"45","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_copy_resolved","op_id":"canary-v4-34","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000011"},"parent_version":1,"payload":{"other_txn_id":"01JC0000000000000000000010","decision":"keep_both"}}]}
{"seq":"46","writer_id":"ios-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","ops":[{"v":4,"type":"txn_ingested","op_id":"canary-v4-36","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000012"},"parent_version":null,"ingest_id":"00000000000000000000000000000000000000000000000000000000000000ac","payload":{"amount_minor":"314159","currency":"AED","direction":"debit","posted_at":"2020-02-05T10:43:00.000Z","posted_precision":"time","merchant_raw":"DIB TRANSFER","last4":"0909","category":null,"needs_review":true,"tier":"template","entry_method":"mailbox","bank":"dib","gates":{"ar":"pass","sender":"trusted","template":"dib.transfer.v1@1","card":"unknown","forwarded":false},"provenance":{"provider":"gmail","grant_id":"g3/mbx-00000000000000000000000000000003","message_id":"c12"}}},{"v":4,"type":"txn_ingested","op_id":"canary-v4-37","authored_at":"2020-02-01T00:00:00.000Z","entity":{"kind":"txn","id":"01JC0000000000000000000013"},"parent_version":null,"ingest_id":"00000000000000000000000000000000000000000000000000000000000000ad","payload":{"amount_minor":"314159","currency":"AED","direction":"debit","posted_at":"2020-02-05T10:46:00.000Z","posted_precision":"time","merchant_raw":"MB FUND TRANSFER DEBIT","last4":"0606","category":null,"needs_review":true,"tier":"template","entry_method":"mailbox","bank":"dib","gates":{"ar":"pass","sender":"trusted","template":"dib.account.v1@3","card":"unknown","forwarded":false},"provenance":{"provider":"gmail","grant_id":"g3/mbx-00000000000000000000000000000003","message_id":"c13"}}}]}
"""

  /// The canary as blobs of ops, in seq order.
  public static func log() -> [(seq: Int64, writerID: String, ops: [Op])] {
    var out: [(Int64, String, [Op])] = []
    for line in text.split(separator: "\n") {
      guard let item = try? JSONParser.parse(Array(line.utf8)), let seq = item["seq"]?.stringValue.flatMap({ Int64($0) }),
        let writer = item["writer_id"]?.stringValue, let ops = item["ops"]?.arrayValue
      else { continue }
      let v = ops.compactMap { $0["v"]?.numberValue?.int64Value }.max() ?? 1
      let body = JSONWriter().bytes(.object(JSONObject([("v", .number(JSONNumber(v))), ("kind", .string("ops")), ("ops", .array(ops))])))
      guard let decoded = try? OpCodec.decodeBlobOps(body) else { continue }
      out.append((seq, writer, decoded))
    }
    return out
  }

  /// The canary folded.
  public static func state() -> State {
    var s = State()
    for (seq, writer, ops) in log() { try? Replay.foldOps(ops, seq: seq, writerID: writer, into: &s) }
    return s
  }

  /// First 32 hex digits of SHA-256(serializeState(fold(canary))), computed once per process.
  public static let foldPrint: String = String(state().serializedSHA256().prefix(32))
}

/// The fold snapshot (spec 04 §5.3): the whole state, delivery bookkeeping and
/// `maxAuthored` included, with every map's insertion order.
public struct StateSnapshot: Sendable, Codable, Equatable {
  public static let currentFormat = 2
  public var formatVersion: Int
  public var foldPrint: String
  public var state: State

  public init(state: State) {
    formatVersion = Self.currentFormat
    foldPrint = FoldCanary.foldPrint
    self.state = state
  }
}

public enum SnapshotError: Error, Sendable, Equatable {
  case undecodable
  case version
  case foldSemantics
}

public enum SnapshotCodec {
  /// The binary property list of `snapshot`.
  public static func encode(_ snapshot: StateSnapshot) throws -> Data {
    let e = PropertyListEncoder()
    e.outputFormat = .binary
    return try e.encode(snapshot)
  }

  /// Decodes a payload, refusing another format or other fold semantics.
  public static func decode(_ data: Data) throws(SnapshotError) -> StateSnapshot {
    let s: StateSnapshot
    do {
      s = try PropertyListDecoder().decode(StateSnapshot.self, from: data)
    } catch {
      throw .undecodable
    }
    guard s.formatVersion == StateSnapshot.currentFormat else { throw .version }
    guard s.foldPrint == FoldCanary.foldPrint else { throw .foldSemantics }
    return s
  }

  /// `digest` = SHA-256(payload), lower-case hex.
  public static func digest(_ data: Data) -> String { Hex.encode(sha256(data)) }
}
