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
    if (url) release();
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
        release();
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
