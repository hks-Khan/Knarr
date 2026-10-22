import { it, expect } from "vitest";
import { createParser } from "@openuidev/react-lang";
import { library, calculator, prompt } from "./library";
it("the shipped calculator parses against exactly the shipped component schema", () => {
  const result = createParser(library.toJSONSchema()).parse(calculator);
  expect(result.root).not.toBeNull();
  expect(result.meta.errors).toEqual([]);
  expect(result.stateDeclarations.$hours).toBe(4);
});
it("allows partial component streams without executing external tools", () => {
  const result = createParser(library.toJSONSchema()).parse(
    'root = Stack([Heading("준비"), Slider($hours, "시간", 1, 12',
  );
  expect(result.queryStatements).toEqual([]);
  expect(result.mutationStatements).toEqual([]);
});
it("generated model instructions use inline UI and the current native action boundary", () => {
  expect(prompt).toContain("Slider(");
  expect(prompt).toContain("Knarr owns those versioned cards");
  expect(prompt).not.toContain("Your ENTIRE response must be valid");
});
