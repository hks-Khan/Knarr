// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, expect, it, vi } from "vitest";
import { ArchivedMessage, Copy, Question, type RowData } from "./app";
(globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
const containers: HTMLElement[] = [];
afterEach(() => { containers.splice(0).forEach(e => e.remove()); });
it("a mobile question becomes answerable again when upload failure returns it to pending", async () => {
  const host = document.createElement("div"); document.body.append(host); containers.push(host);
  const root = createRoot(host);
  const posted = vi.fn(); (window as any).webkit = {messageHandlers:{knarr:{postMessage:posted}}};
  const row: RowData = {id:"retry-question",kind:"question",text:"",time:"11:00",attachments:[],state:{},
    question:{id:"q",asker:"Hird",prompt:"선택",options:["가","나"],multiple:false,status:"pending",summary:""}};
  await act(async () => root.render(<Question row={row} readOnly={false} isMobile />));
  const answer = () => [...host.querySelectorAll("button")].find(b => b.textContent === "답변")!;
  await act(async () => (host.querySelector(".choices button") as HTMLButtonElement).click());
  await act(async () => answer().click());
  expect(posted.mock.calls.at(-1)?.[0]).toMatchObject({action:"answer",message:"retry-question",selected:["가"]});
  expect(answer().matches(":disabled")).toBe(true);
  await act(async () => root.render(<Question row={{...row,question:{...row.question!,status:"answered",summary:"전달 대기"}}} readOnly={false} isMobile />));
  await act(async () => root.render(<Question row={row} readOnly={false} isMobile />));
  expect(answer().matches(":disabled")).toBe(false);
  await act(async () => root.unmount());
});

it("retained issue and question messages remain readable without their live records", async () => {
  const host = document.createElement("div"); document.body.append(host); containers.push(host);
  const root = createRoot(host);
  for (const title of ["이슈", "질문"]) {
    const row: RowData = {id:"retained",kind:"archived",title,text:"지난 기록 본문",time:"11:00",attachments:[],state:{}};
    await act(async () => root.render(<ArchivedMessage row={row} />));
    expect(host.textContent).toContain("지난 기록 본문");
    expect(host.querySelector("button")).toBeNull();
  }
  await act(async () => root.unmount());
});
it("copy feedback accepts only the acknowledged request", async () => {
  const host = document.createElement("div"); document.body.append(host); containers.push(host);
  const root = createRoot(host);
  const posted = vi.fn(); (window as any).webkit = {messageHandlers:{knarr:{postMessage:posted}}};
  await act(async () => root.render(<Copy id="copied-row" />));
  await act(async () => (host.querySelector("button") as HTMLButtonElement).click());
  const request = posted.mock.calls.at(-1)?.[0].request;
  await act(async () => window.dispatchEvent(new CustomEvent("knarr-result",{detail:{message:"copied-row",request:"stale",error:null}})));
  expect(host.querySelector("button")?.getAttribute("aria-label")).toBe("복사");
  await act(async () => window.dispatchEvent(new CustomEvent("knarr-result",{detail:{message:"copied-row",request,error:null}})));
  expect(host.querySelector("button")?.getAttribute("aria-label")).toBe("복사됨");
  await act(async () => root.unmount());
});
