export function privatePhotoControl({ name, open, release, onError }) {
  const element = document.createElement("div");
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "Посмотреть фото";
  element.append(button);

  let image = null;
  let url = null;
  let busy = false;
  let disposed = false;

  const hide = () => {
    if (url) release(url);
    url = null;
    image?.remove();
    image = null;
    button.textContent = "Посмотреть фото";
  };

  button.addEventListener("click", async () => {
    if (disposed || busy) return;
    if (url) {
      hide();
      return;
    }
    busy = true;
    button.disabled = true;
    try {
      const result = await open();
      if (disposed) {
        release(result);
        return;
      }
      url = result;
      image = document.createElement("img");
      image.className = "private-photo-preview";
      image.alt = name;
      image.decoding = "async";
      image.loading = "lazy";
      image.src = url;
      element.insertBefore(image, button);
      button.textContent = "Скрыть фото";
    } catch (error) {
      if (!disposed) onError(error);
    } finally {
      busy = false;
      if (!disposed) button.disabled = false;
    }
  });

  return {
    element,
    dispose() {
      if (disposed) return;
      disposed = true;
      hide();
      element.remove();
    },
  };
}

// Check advertised dimensions before passing any compressed pixels to the
// browser. The caller checks the decoded bitmap again (including EXIF rotation).
export function photoHeader(bytes) {
  const invalid = () => { throw Object.assign(new Error("Unsupported or oversized image"), {code: "attachment"}); };
  if (bytes.length < 12 || bytes.length > 4 * 1024 * 1024) invalid();
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (offset) => view.getUint32(offset);
  function checked(mime, width, height) {
    if (!width || !height || width > 8192 || height > 8192 || width * height > 16_000_000) invalid();
    return {mime, width, height};
  }
  if (tag(0) === 0x89504e47 && tag(4) === 0x0d0a1a0a) {
    if (bytes.length < 29 || tag(8) !== 13 || tag(12) !== 0x49484452) invalid();
    return checked("image/png", tag(16), tag(20));
  }
  if (view.getUint16(0) === 0xffd8) {
    let p = 2;
    while (p + 4 <= bytes.length && bytes[p++] === 0xff) {
      while (p < bytes.length && bytes[p] === 0xff) p++;
      const marker = bytes[p++];
      if (marker === 0xda || marker === 0xd9 || p + 2 > bytes.length) invalid();
      const length = view.getUint16(p);
      if (length < 2 || p + length > bytes.length) invalid();
      if ([0xc0, 0xc1, 0xc2].includes(marker)) {
        if (length < 8 || length !== 8 + 3 * bytes[p + 7]) invalid();
        return checked("image/jpeg", view.getUint16(p + 5), view.getUint16(p + 3));
      }
      p += length;
    }
    invalid();
  }
  if (tag(0) !== 0x52494646 || tag(8) !== 0x57454250 ||
      view.getUint32(4, true) !== bytes.length - 8) invalid();
  let canvas, frame;
  for (let offset = 12; offset < bytes.length;) {
    const p = offset + 8;
    if (p > bytes.length) invalid();
    const length = view.getUint32(offset + 4, true);
    const next = p + length + (length % 2);
    if (next > bytes.length) invalid();
    const type = tag(offset);
    if (type === 0x56503858) { // VP8X extended canvas
      if (offset !== 12 || length !== 10 || bytes[p] & 2) invalid();
      const u24 = (i) => bytes[i] + 256 * bytes[i + 1] + 65536 * bytes[i + 2];
      canvas = checked("image/webp", 1 + u24(p + 4), 1 + u24(p + 7));
    } else if (type === 0x56503820) { // VP8 key frame
      if (frame || length < 10 || bytes[p] & 1 || bytes[p + 3] !== 0x9d ||
          view.getUint16(p + 4) !== 0x012a) invalid();
      frame = checked("image/webp", view.getUint16(p + 6, true) & 0x3fff,
                      view.getUint16(p + 8, true) & 0x3fff);
    } else if (type === 0x5650384c) { // VP8L
      if (frame || length < 5 || bytes[p] !== 0x2f) invalid();
      const bits = view.getUint32(p + 1, true);
      frame = checked("image/webp", 1 + (bits & 0x3fff), 1 + ((bits >>> 14) & 0x3fff));
    } else if (type === 0x414e494d || type === 0x414e4d46) {
      invalid();
    }
    offset = next;
  }
  if (!frame || (canvas && (frame.width !== canvas.width || frame.height !== canvas.height))) invalid();
  return frame;
}
