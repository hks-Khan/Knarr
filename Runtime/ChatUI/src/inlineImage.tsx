import React, { useState } from "react";

/** Local transcript images; the native side mints these addresses and serves the bytes. */
export const IMAGE_SCHEME = "chat-image";
/** Shown when a local path is missing or was refused, and when a served file stops loading. */
export const MISSING_IMAGE = "이미지를 찾을 수 없어요";
/** Shown for http(s) addresses, which Knarr never fetches. */
export const EXTERNAL_IMAGE = "외부 이미지는 표시하지 않아요";

/** The address Knarr minted for a local picture, if this is one of them. */
export function mintedAddress(src: unknown): string | null {
  return typeof src === "string" && src.startsWith(`${IMAGE_SCHEME}://image/`)
    ? src
    : null;
}

/** Nur text: which picture is missing, so the reader can still tell them apart. */
function withAlt(message: string, alt?: string): string {
  const name = alt?.trim();
  return name ? `${message} · ${name}` : message;
}

/**
 * One Markdown image. Only addresses Knarr minted for a local file are loaded; every other
 * address — missing, refused or remote — becomes a short status instead of a broken picture.
 */
export function InlineImage({
  alt,
  src,
  onOpen,
}: {
  alt?: string;
  src: unknown;
  onOpen: (address: string) => void;
}) {
  const address = mintedAddress(src);
  const [failed, setFailed] = useState(false);
  if (!address || failed) {
    // A refused local path and a stopped load read the same; only remote addresses differ.
    const remote =
      !address && typeof src === "string" && /^https?:/i.test(src.trim());
    return (
      <span className="image-status">
        {withAlt(remote ? EXTERNAL_IMAGE : MISSING_IMAGE, alt)}
      </span>
    );
  }
  return (
    <button
      type="button"
      className="inline-image"
      title={alt ?? ""}
      onClick={() => onOpen(address)}
    >
      <img
        src={address}
        alt={alt ?? ""}
        loading="lazy"
        onError={() => setFailed(true)}
      />
    </button>
  );
}
