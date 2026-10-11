import { expect, test } from "bun:test";
import { asciiJSON } from "./conformance-io";

test("asciiJSON escapes everything above U+007E and keeps surrogate pairs", () => {
  expect(asciiJSON({ a: " \u{1f600}~" })).toBe('{\n  "a": "\\u00a0\\ud83d\\ude00~"\n}\n');
});

test("asciiJSON refuses a lone surrogate in a value or a key", () => {
  expect(() => asciiJSON({ a: "x\ud800y" })).toThrow(/lone high surrogate/);
  expect(() => asciiJSON({ a: ["x\ud800"] })).toThrow(/lone high surrogate/);
  expect(() => asciiJSON({ a: "\ude00y" })).toThrow(/lone low surrogate/);
  expect(() => asciiJSON({ ["k\udc00"]: 1 })).toThrow(/lone low surrogate/);
});

test("asciiJSON refuses a string that starts with U+FEFF", () => {
  expect(() => asciiJSON({ a: "﻿x" })).toThrow(/U\+FEFF/);
  expect(asciiJSON({ a: "x﻿" })).toBe('{\n  "a": "x\\ufeff"\n}\n');
});
