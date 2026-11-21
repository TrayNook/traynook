import assert from 'node:assert/strict';
import test from 'node:test';
import { captureBounds, captureSlots, updateCapture } from '../src/scripts/capture-stage.mjs';

const items = ['blue', 'pink', 'aqua', 'plane'];

function drawsFor(open, ids) {
  const image = {};
  const draws = [];
  const ctx = { drawImage(source, ...rects) { assert.equal(source, image); draws.push(rects); } };
  for (const name of ['clearRect', 'save', 'restore', 'beginPath', 'moveTo', 'lineTo', 'quadraticCurveTo', 'roundRect', 'clip']) {
    ctx[name] = () => {};
  }
  const canvas = { width: 0, height: 0, getContext: () => ctx };
  assert.equal(updateCapture(canvas, image, open, ids), true);
  assert.deepEqual([canvas.width, canvas.height], [532, 234]);
  return draws;
}

test('every row stays centered on the photographed launcher, with the gear first and reachable', () => {
  assert.deepEqual(captureBounds(items), { x: 20, y: 86, width: 480, height: 124 });
  assert.deepEqual(captureSlots(items).map(s => s.x + s.width / 2), [84, 172, 260, 348, 436]);
  for (const length of [0, 1, 2, 3, 4]) {
    const ids = items.slice(0, length).reverse();
    const body = captureBounds(ids);
    const slots = captureSlots(ids);
    assert.equal(body.x + body.width / 2, 260);
    assert.deepEqual(slots.map(s => s.id), ['settings', ...ids]);
    assert.equal(slots[0].x - body.x, 20);
    assert.equal(body.x + body.width - (slots.at(-1).x + slots.at(-1).width), 20);
    assert.ok(slots.every(s => s.y + s.height / 2 === 148));
  }
});

test('the original order draws the photograph unchanged and closing removes the entire popover', () => {
  assert.deepEqual(drawsFor(true, items), [[0, 0]]);
  assert.deepEqual(drawsFor(false, items), [[0, 0, 532, 62, 0, 0, 532, 62]]);
});

test('edited layout uses each chosen glyph at native size under its new hotspot', () => {
  for (const ids of [[], ['plane'], ['pink', 'blue'], ['aqua', 'plane', 'blue', 'pink']]) {
    const draws = drawsFor(true, ids);
    const icons = draws.filter(rect => rect[1] === 126 && rect[2] === 44);
    const centers = captureSlots(ids).slice(1).map(slot => slot.x + slot.width / 2);
    assert.deepEqual(icons.map(rect => rect[0] + 22), ids.map(id => 172 + 88 * items.indexOf(id)));
    assert.deepEqual(icons.map(rect => rect[4] + 22), centers);
    assert.ok(icons.every(rect => rect[2] === rect[6] && rect[3] === rect[7]));
  }
});
