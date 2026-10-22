// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, expect, test } from "vitest";
import { InlineImage } from "./inlineImage";

afterEach(() => {
  document.body.innerHTML = "";
});

function render(node: React.ReactElement) {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  act(() => root.render(node));
  return host;
}

test("an address Knarr never minted shows why there is no picture", () => {
  const host = render(
    <InlineImage alt="없는 파일" src="/nope/gone.png" onOpen={() => {}} />,
  );
  const status = host.querySelector(".image-status")!;
  expect(status.textContent).toContain("이미지를 찾을 수 없어요");
  expect(status.textContent).toContain("없는 파일");
  expect(host.querySelector("img")).toBeNull();
});

test("a remote address is named as such and never loaded", () => {
  const host = render(
    <InlineImage alt="외부 그림" src="https://example.org/x.png" onOpen={() => {}} />,
  );
  const status = host.querySelector(".image-status")!;
  expect(status.textContent).toContain("외부 이미지는 표시하지 않아요");
  expect(host.querySelector("img")).toBeNull();
});

test("a picture that fails while loading becomes the same status", () => {
  const host = render(
    <InlineImage alt="확인 화면" src="chat-image://image/abc" onOpen={() => {}} />,
  );
  const image = host.querySelector("img")!;
  expect(image.getAttribute("src")).toBe("chat-image://image/abc");
  act(() => image.dispatchEvent(new Event("error")));
  const status = host.querySelector(".image-status")!;
  expect(status.textContent).toContain("이미지를 찾을 수 없어요");
  expect(status.textContent).toContain("확인 화면");
  expect(host.querySelector("img")).toBeNull();
});

test("a served picture opens through the button and keeps its alt", () => {
  const opened: string[] = [];
  const host = render(
    <InlineImage alt="확인 화면" src="chat-image://image/abc" onOpen={(a) => opened.push(a)} />,
  );
  const button = host.querySelector(".inline-image")! as HTMLButtonElement;
  expect(button.title).toBe("확인 화면");
  expect(host.querySelector(".image-status")).toBeNull();
  act(() => button.click());
  expect(opened).toEqual(["chat-image://image/abc"]);
});
