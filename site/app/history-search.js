export const timelinePageSize = 100;

export function searchText(text) {
  return text.normalize("NFC").toLowerCase();
}

export function matchesHistory(message, query) {
  return Boolean(query && typeof message?.text === "string" && message.status !== "unsupported" &&
    searchText(message.text).includes(query));
}

// Scan in the requested direction without copying history or storing match lists.
export function findHistory(messages, query, start, step) {
  if (!query) return -1;
  for (let index = start; index >= 0 && index < messages.length; index += step) {
    if (matchesHistory(messages[index], query)) return index;
  }
  return -1;
}

export function historyPage(length, index) {
  const start = Math.floor(index / timelinePageSize) * timelinePageSize;
  return [start, Math.min(start + timelinePageSize, length)];
}
