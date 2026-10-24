// 03c §6: `project_defined` and `goal_defined`, versioned entities folded
// through the reference causal engine (whole-record replacement, forks by
// `authored_at` then writer). The decoders here check the payload grammar only.
import CoreJSON
import CoreWire

extension State {
  static func decodeProject(_ p: JSONObject) throws(PayloadError) -> Project {
    let name = try P.label(p["name"], "name")
    let starts = P.present(p["starts_on"]) == nil ? nil : try P.civilDate(p["starts_on"], "starts_on")
    let ends = P.present(p["ends_on"]) == nil ? nil : try P.civilDate(p["ends_on"], "ends_on")
    if let s = starts, let e = ends, e < s { throw PayloadError("ends_on is before starts_on") }
    let budget = P.present(p["budget_minor"]) == nil ? nil : try P.minorV4(p["budget_minor"], "budget_minor", positive: true)
    let count = try P.boolField(p["count_in_plan"], "count_in_plan")
    let status = try P.oneOf(p["status"], "status", ["active", "completed", "removed"])
    let completed = P.present(p["completed_on"]) == nil ? nil : try P.civilDate(p["completed_on"], "completed_on")
    if (status == "completed") != (completed != nil) { throw PayloadError("completed_on is present iff status is completed") }
    let icon = try optionalIcon(p["icon"])
    return Project(
      name: name, startsOn: starts, endsOn: ends, budgetMinor: budget, countInPlan: count, status: status,
      completedOn: completed, icon: icon, createdAt: "", version: 0)
  }

  static func decodeGoal(_ p: JSONObject) throws(PayloadError) -> Goal {
    let name = try P.label(p["name"], "name")
    let target = try P.minorV4(p["target_minor"], "target_minor", positive: true)
    let month = P.present(p["target_month"]) == nil ? nil : try P.civilMonth(p["target_month"], "target_month")
    let so = try P.object(p["source"], "source")
    let kind = try P.oneOf(so["kind"], "source.kind", ["category", "account"])
    let source: GoalSource
    if kind == "category" {
      source = GoalSource(
        kind: kind, categoryID: try P.categoryID(so["category_id"], "source.category_id"),
        since: try P.civilDate(so["since"], "source.since"), accountID: nil)
    } else {
      source = GoalSource(kind: kind, categoryID: nil, since: nil, accountID: try P.id03b(so["account_id"], "source.account_id"))
    }
    let starting = P.present(p["starting_minor"]) == nil ? 0 : try P.minorV4(p["starting_minor"], "starting_minor")
    let status = try P.oneOf(p["status"], "status", ["active", "completed", "removed"])
    let completed = P.present(p["completed_on"]) == nil ? nil : try P.civilDate(p["completed_on"], "completed_on")
    if (status == "completed") != (completed != nil) { throw PayloadError("completed_on is present iff status is completed") }
    let icon = try optionalIcon(p["icon"])
    return Goal(
      name: name, targetMinor: target, targetMonth: month, source: source, startingMinor: starting, status: status,
      completedOn: completed, icon: icon, createdAt: "", version: 0)
  }

  static func optionalIcon(_ v: JSONValue?) throws(PayloadError) -> String? {
    guard let v = P.present(v) else { return nil }
    guard let s = v.stringValue, Grammar.isIconID(s) else { throw PayloadError("icon must be an IconId, got \(showValue(v))") }
    return s
  }
}
