export const INITIAL_ITEMS = [
  { id: 'sound', name: 'Sound', icon: 'headphones.svg', tone: 'sand', group: 'menu' },
  { id: 'timer', name: 'Timer', icon: 'clock.svg', tone: 'orange', group: 'dropdown' },
  { id: 'clipboard', name: 'Clipboard', icon: 'clipboard.svg', tone: 'violet', group: 'dropdown' },
  { id: 'display', name: 'Display', icon: 'sun.svg', tone: 'green', group: 'dropdown' },
  { id: 'cloud', name: 'Cloud', icon: 'cloud.svg', tone: 'blue', group: 'dropdown' },
  { id: 'focus', name: 'Focus', icon: 'bell.svg', tone: 'rose', group: 'hidden' },
];

export function moveItem(items, id, group, before = null) {
  const item = items.find(item => item.id === id);
  const anchor = before === null ? null : items.find(item => item.id === before);
  if (!item || !['menu', 'dropdown', 'hidden'].includes(group) || id === before
      || (before !== null && (!anchor || anchor.group !== group))) return items;

  const remaining = items.filter(item => item.id !== id);
  const lastInGroup = remaining.findLastIndex(item => item.group === group);
  const index = before === null
    ? (lastInGroup === -1 ? remaining.length : lastInGroup + 1)
    : remaining.findIndex(item => item.id === before);
  remaining.splice(index, 0, { ...item, group });
  return remaining;
}
