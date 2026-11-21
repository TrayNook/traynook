import assert from 'node:assert/strict';
import test from 'node:test';
import { initialLayout, moveItem } from '../src/scripts/practice-layout.mjs';

test('a move changes only the selected icon and reset reconstructs the captured order', () => {
  const initial = initialLayout();
  const moved = moveItem(moveItem(initial, 'plane', 'menu'), 'pink', 'hidden');
  assert.deepEqual(moved, { menu: ['plane'], dropdown: ['blue', 'aqua'], hidden: ['pink'] });
  const reset = initialLayout();
  assert.deepEqual(initial, reset);
  assert.deepEqual(reset.dropdown, ['blue', 'pink', 'aqua', 'plane']);
});

test('drop before an icon reorders within a lane or moves between lanes', () => {
  const initial = initialLayout();
  const reordered = moveItem(initial, 'plane', 'dropdown', 'blue');
  assert.deepEqual(reordered.dropdown, ['plane', 'blue', 'pink', 'aqua']);
  const allInMenu = ['blue', 'pink', 'aqua', 'plane'].reduce((state, id) => moveItem(state, id, 'menu'), initial);
  assert.deepEqual(allInMenu.dropdown, []);
  const movedBack = moveItem(moveItem(allInMenu, 'pink', 'dropdown'), 'plane', 'dropdown', 'pink');
  assert.deepEqual(movedBack.dropdown, ['plane', 'pink']);
});

test('unrelated drags, invalid destinations, and unchanged drops keep the same state', () => {
  const layout = initialLayout();
  for (const [id, group, before] of [
    ['other', 'menu'], ['blue', 'elsewhere'], ['blue', 'menu', 'plane'],
    ['pink', 'dropdown', 'pink'], ['blue', 'dropdown', 'pink'], ['plane', 'dropdown'],
  ]) {
    assert.equal(moveItem(layout, id, group, before), layout);
  }
});
