import { describe, expect, it } from "vitest";

import { CSV_HEADER, generate } from "./playseed.mjs";

const OPTS = { endDate: "2026-08-16", months: 6, seed: 20260816 };

/** Parse a CSV line that may contain RFC4180 double-quoted fields. */
function parseLine(line) {
  const out = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const c = line[i];
    if (quoted) {
      if (c === '"' && line[i + 1] === '"') { field += '"'; i += 1; }
      else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ",") { out.push(field); field = ""; }
    else field += c;
  }
  out.push(field);
  return out;
}

describe("playseed.generate", () => {
  it("is deterministic — same options, identical bytes", () => {
    expect(generate(OPTS).csv).toBe(generate(OPTS).csv);
  });

  it("starts with CSV_HEADER, the literal v2nav.mjs's import walk also asserts, and ends with a trailing newline", () => {
    const { csv } = generate(OPTS);
    expect(csv.split("\n")[0]).toBe(CSV_HEADER);
    expect(CSV_HEADER).toBe("Date,Description,Amount,Category");
    expect(csv.endsWith("\n")).toBe(true);
  });

  it("produces months of data, not a handful of rows", () => {
    const { rows } = generate(OPTS);
    expect(rows.length).toBeGreaterThanOrEqual(200);
    expect(rows.length).toBeLessThanOrEqual(420);
  });

  it("runs in ascending date order inside the requested window", () => {
    const { rows } = generate(OPTS);
    const dates = rows.map((r) => r[0]);
    expect([...dates].sort()).toEqual(dates);
    expect(dates[0] >= "2026-02-16").toBe(true);
    expect(dates[dates.length - 1] <= "2026-08-16").toBe(true);
  });

  it("writes every amount as signed minor-unit-safe decimal, never zero", () => {
    for (const [, , amount] of generate(OPTS).rows) {
      expect(amount).toMatch(/^-?\d+\.\d{2}$/);
      expect(amount).not.toBe("0.00");
      expect(amount).not.toBe("-0.00");
    }
  });

  it("pays a salary once a month, as a credit", () => {
    const salary = generate(OPTS).rows.filter((r) => r[1].startsWith("SALARY"));
    expect(salary).toHaveLength(6);
    for (const r of salary) {
      expect(Number(r[2])).toBeGreaterThan(0);
      expect(r[3]).toBe("Income");
    }
  });

  it("leaves a workable minority uncategorised, so the review deck has cards", () => {
    const { rows } = generate(OPTS);
    const blank = rows.filter((r) => r[3] === "").length;
    expect(blank / rows.length).toBeGreaterThan(0.05);
    expect(blank / rows.length).toBeLessThan(0.2);
  });

  it("quotes a merchant containing a comma so the file still parses as 4 columns", () => {
    const { csv, rows } = generate(OPTS);
    expect(rows.some((r) => r[1].includes(","))).toBe(true);
    for (const line of csv.trim().split("\n")) {
      expect(parseLine(line)).toHaveLength(4);
    }
  });

  it("is plausible, not hostile — no fixture-width merchants or extreme amounts", () => {
    for (const [, description, amount] of generate(OPTS).rows) {
      expect(description.length).toBeLessThanOrEqual(45);
      expect(Math.abs(Number(amount))).toBeLessThan(50000);
    }
  });
});
