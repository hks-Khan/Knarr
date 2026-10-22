import { useEffect, useRef, useState } from "react";
export function useSmoothText(text: string, streaming: boolean) {
  const [hidden, setHidden] = useState(document.hidden);
  useEffect(() => {
    const changed = () => setHidden(document.hidden);
    document.addEventListener("visibilitychange", changed);
    return () => document.removeEventListener("visibilitychange", changed);
  }, []);
  const [shown, setShown] = useState(streaming ? "" : text);
  const visible = useRef(shown);
  const previous = useRef("");
  useEffect(() => {
    if (!streaming || hidden || !text.startsWith(previous.current)) {
      previous.current = text;
      visible.current = text;
      setShown(text);
      return;
    }
    previous.current = text;
    const segmenter = new Intl.Segmenter("ko", { granularity: "grapheme" });
    const boundaries = [...segmenter.segment(text)].map(
      (s) => s.index + s.segment.length,
    );
    let index = boundaries.findIndex((end) => end > visible.current.length);
    if (index < 0) return;
    let frame = 0,
      last = performance.now(),
      credit = 0;
    const speed = Math.max(60, (boundaries.length - index) / 0.15);
    const tick = (now: number) => {
      credit += speed * Math.min(0.032, (now - last) / 1000);
      last = now;
      const count = Math.floor(credit);
      credit -= count;
      index = Math.min(boundaries.length, index + count);
      if (index > 0) {
        visible.current = text.slice(0, boundaries[index - 1]);
        setShown(visible.current);
      }
      if (index < boundaries.length) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [text, streaming, hidden]);
  return streaming && !hidden ? shown : text;
}
