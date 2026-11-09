import assert from 'node:assert/strict';
import test from 'node:test';
import { INITIAL_ITEMS, moveItem } from '../src/scripts/demo-state.mjs';

const ids = (items, group) => items.filter(item => item.group === group).map(item => item.id);

test('moves an item to the end of another group', () => {
  const moved = moveItem(INITIAL_ITEMS, 'sound', 'dropdown');
  assert.deepEqual(ids(moved, 'menu'), []);
  assert.deepEqual(ids(moved, 'dropdown'), ['timer', 'clipboard', 'display', 'cloud', 'sound']);
  assert.deepEqual(ids(moved, 'hidden'), ['focus']);
});

test('inserts into another group before its anchor', () => {
  const moved = moveItem(INITIAL_ITEMS, 'focus', 'dropdown', 'clipboard');
  assert.deepEqual(ids(moved, 'dropdown'), ['timer', 'focus', 'clipboard', 'display', 'cloud']);
  assert.deepEqual(ids(moved, 'hidden'), []);
});

test('reorders within a group and appends to its end', () => {
  const reordered = moveItem(INITIAL_ITEMS, 'cloud', 'dropdown', 'clipboard');
  assert.deepEqual(ids(reordered, 'dropdown'), ['timer', 'cloud', 'clipboard', 'display']);
  assert.deepEqual(ids(moveItem(reordered, 'timer', 'dropdown'), 'dropdown'),
    ['cloud', 'clipboard', 'display', 'timer']);
});

test('does not mutate the input array or its items', () => {
  const snapshot = structuredClone(INITIAL_ITEMS);
  const frozen = Object.freeze(INITIAL_ITEMS.map(item => Object.freeze({ ...item })));
  const moved = moveItem(frozen, 'timer', 'hidden');
  assert.deepEqual(INITIAL_ITEMS, snapshot);
  assert.deepEqual(frozen, snapshot);
  assert.notStrictEqual(moved, frozen);
  assert.notStrictEqual(moved.find(item => item.id === 'timer'), frozen[1]);
  assert.strictEqual(moved.find(item => item.id === 'sound'), frozen[0]);
});

test('invalid IDs, groups, and anchors leave the input unchanged', () => {
  for (const args of [
    ['missing', 'menu'],
    ['timer', 'missing'],
    ['timer', 'menu', 'missing'],
    ['timer', 'menu', 'cloud'],
    ['timer', 'dropdown', 'timer'],
  ]) assert.strictEqual(moveItem(INITIAL_ITEMS, ...args), INITIAL_ITEMS);
});

test('keeps each item once and preserves lane order when emptying and refilling dropdown', () => {
  let items = INITIAL_ITEMS;
  for (const id of ['timer', 'clipboard', 'display', 'cloud']) items = moveItem(items, id, 'hidden');
  assert.deepEqual(ids(items, 'dropdown'), []);
  assert.deepEqual(ids(items, 'menu'), ['sound']);
  assert.deepEqual(ids(items, 'hidden'), ['focus', 'timer', 'clipboard', 'display', 'cloud']);

  items = moveItem(items, 'clipboard', 'dropdown');
  assert.deepEqual(ids(items, 'dropdown'), ['clipboard']);
  assert.deepEqual(ids(items, 'hidden'), ['focus', 'timer', 'display', 'cloud']);
  assert.deepEqual(items.map(item => item.id).sort(), INITIAL_ITEMS.map(item => item.id).sort());
  assert.equal(new Set(items.map(item => item.id)).size, INITIAL_ITEMS.length);
});
