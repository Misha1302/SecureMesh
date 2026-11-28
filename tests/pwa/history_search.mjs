import assert from "node:assert/strict";
import { findHistory, historyPage, searchText } from "../../site/app/history-search.js";

const messages = Array.from({length: 10000}, (_, index) => ({text: String(index)}));
messages[1] = {text: "СТАРАЯ Игла"};
messages[110] = {text: "Игла в неподдерживаемом событии", status: "unsupported"};
messages[3000] = {text: "игла CAFÉ"};
const query = searchText("ИГЛА");
assert.equal(findHistory(messages, query, messages.length - 1, -1), 3000);
assert.equal(findHistory(messages, query, 2999, -1), 1);
assert.equal(findHistory(messages, query, 2, 1), 3000);
assert.equal(findHistory(messages, searchText("cafe\u0301"), 0, 1), 3000);
assert.equal(findHistory(messages, searchText("нет совпадений"), 0, 1), -1);
assert.deepEqual(historyPage(messages.length, 1), [0, 100]);
assert.deepEqual(historyPage(messages.length, 3000), [3000, 3100]);
assert.deepEqual(historyPage(101, 100), [100, 101]);
