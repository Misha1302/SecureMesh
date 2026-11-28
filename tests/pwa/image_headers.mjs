import assert from 'node:assert/strict';
import { photoHeader } from '../../site/app/private-image.js';

// Synthetic headers are enough to check bounds before invoking the pixel decoder.
const png = Buffer.from('89504e470d0a1a0a0000000d4948445200000002000000010802000000', 'hex');
const jfif = Buffer.from('ffd8ffe000064a464946ffc00011080001000203012200021101031101ffda','hex');
assert.deepEqual(photoHeader(png), {mime:'image/png', width:2, height:1});
assert.deepEqual(photoHeader(jfif), {mime:'image/jpeg', width:2, height:1});
const lossless = Buffer.from('5249464612000000574542505650384c050000002f0100000000','hex');
assert.deepEqual(photoHeader(lossless), {mime:'image/webp', width:2, height:1});
assert.throws(() => photoHeader(png.subarray(0, 21)));
const large = Buffer.from(png);
large.writeUInt32BE(6000, 16); large.writeUInt32BE(6000, 20);
assert.throws(() => photoHeader(large));
const malformed = Buffer.from(jfif);
malformed.writeUInt16BE(1, 4);
assert.throws(() => photoHeader(malformed));
assert.throws(() => photoHeader(lossless.subarray(0, 21)));
