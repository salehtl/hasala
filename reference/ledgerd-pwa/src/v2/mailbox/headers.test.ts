import { describe, expect, it } from "vitest";

import { headerBlock } from "./headers";

describe("headerBlock", () => {
  it("stops at the CRLF CRLF that ends a header block", () => {
    expect(headerBlock("From: a@b.test\r\nSubject: x\r\n\r\nbody\r\nmore")).toBe("From: a@b.test\r\nSubject: x");
  });

  it("accepts bare-LF and bare-CR separators too", () => {
    expect(headerBlock("From: a@b.test\nSubject: x\n\nbody")).toBe("From: a@b.test\nSubject: x");
    expect(headerBlock("From: a@b.test\rSubject: x\r\rbody")).toBe("From: a@b.test\rSubject: x");
  });

  it("drops a megabyte of body without touching the headers", () => {
    // The point of the whole module: the A-R parser's 256 KiB ceiling must be
    // spent on headers, not on an HTML bank alert's embedded images.
    const raw = `Authentication-Results: mx.google.com; dkim=pass header.d=dib.ae\r\n\r\n${"x".repeat(1_000_000)}`;
    const block = headerBlock(raw);
    expect(block.length).toBeLessThan(256 * 1024);
    expect(block).toContain("dkim=pass");
  });

  it("returns a message with no blank line whole rather than guessing a cut", () => {
    expect(headerBlock("From: a@b.test\r\nSubject: x")).toBe("From: a@b.test\r\nSubject: x");
    expect(headerBlock("")).toBe("");
  });

  it("keeps folded continuation lines, which are part of the field", () => {
    const raw = "Authentication-Results: mx.google.com;\r\n dkim=pass header.d=dib.ae\r\n\r\nbody";
    expect(headerBlock(raw)).toBe("Authentication-Results: mx.google.com;\r\n dkim=pass header.d=dib.ae");
  });
});
