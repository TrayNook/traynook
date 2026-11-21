import { originalItems } from './capture-stage.mjs';

export function initialLayout() {
  return { menu: [], dropdown: [...originalItems], hidden: [] };
}

function groupOf(layout, id) {
  return Object.keys(layout).find(group => layout[group].includes(id));
}

// A drop over an icon inserts before it. A drop on the lane appends.
export function moveItem(layout, id, destination, before = null) {
  const source = groupOf(layout, id);
  if (!source || !Object.hasOwn(layout, destination) || before === id) return layout;
  const items = layout[destination].filter(item => item !== id);
  const at = before === null ? items.length : items.indexOf(before);
  if (at < 0 || (source === destination && layout[source].indexOf(id) === at)) return layout;

  items.splice(at, 0, id);
  return { ...layout, [source]: layout[source].filter(item => item !== id), [destination]: items };
}

export function setupPractice(root, labels, { onChange, onDone }) {
  const title = root.querySelector('[data-practice-title]');
  const status = root.querySelector('[data-practice-status]');
  const reset = root.querySelector('[data-practice-reset]');
  const earlier = root.querySelector('[data-practice-shift="earlier"]');
  const later = root.querySelector('[data-practice-shift="later"]');
  const rows = new Map([...root.querySelectorAll('[data-practice-group]')]
    .map(row => [row.dataset.practiceGroup, row]));
  const buttons = new Map([...root.querySelectorAll('[data-practice-item]')]
    .map(button => [button.dataset.practiceItem, button]));
  const screenshot = root.ownerDocument.querySelector('a[data-native-capture="dropdown"]');
  root.style.setProperty('--practice-capture', `url("${screenshot.href}")`);

  let layout = initialLayout();
  let selected = null;
  let dragging = null;

  function updateControls() {
    const group = groupOf(layout, selected);
    buttons.forEach((button, id) => button.setAttribute('aria-pressed', String(selected === id)));
    rows.forEach((row, key) => { row.querySelector('[data-move-here]').disabled = !selected || group === key; });
    earlier.disabled = !group || layout[group][0] === selected;
    later.disabled = !group || layout[group].at(-1) === selected;
    reset.disabled = layout.dropdown.join() === initialLayout().dropdown.join();
  }

  function renderLayout() {
    rows.forEach((row, group) => {
      row.querySelector('[data-practice-icons]').replaceChildren(...layout[group].map(id => buttons.get(id)));
    });
    updateControls();
  }

  function announce(template, id, group) {
    status.textContent = template.replace('{item}', labels.names[id]).replace('{group}', rows.get(group).getAttribute('aria-label'));
  }

  function select(id) {
    selected = selected === id ? null : id;
    updateControls();
    if (selected) announce(labels.selected, selected, groupOf(layout, selected));
    else status.textContent = '';
  }

  function move(id, destination, before = null) {
    const next = moveItem(layout, id, destination, before);
    if (next === layout) return;
    layout = next;
    selected = id;
    renderLayout();
    buttons.get(id).focus({ preventScroll: true });
    announce(labels.moved, id, destination);
    onChange();
  }

  root.addEventListener('click', event => {
    const button = event.target.closest('button');
    if (!button || button.disabled) return;
    if (button.hasAttribute('data-practice-item')) {
      select(button.dataset.practiceItem);
    } else if (button.hasAttribute('data-move-here')) {
      move(selected, button.closest('[data-practice-group]').dataset.practiceGroup);
    } else if (button === earlier || button === later) {
      const group = groupOf(layout, selected);
      const order = layout[group];
      const index = order.indexOf(selected);
      move(selected, group, order[button === earlier ? index - 1 : index + 2] ?? null);
    } else if (button === reset) {
      layout = initialLayout();
      selected = null;
      renderLayout();
      status.textContent = labels.restored;
      title.focus({ preventScroll: true });
      onChange();
    } else if (button.hasAttribute('data-practice-done')) {
      onDone();
    }
  });

  function dragEnd() {
    dragging = null;
    rows.forEach(row => row.removeAttribute('data-drop-target'));
  }

  root.addEventListener('dragstart', event => {
    const button = event.target.closest('[data-practice-item]');
    if (!button) return;
    dragging = button.dataset.practiceItem;
    event.dataTransfer.setData('text/plain', dragging);
    event.dataTransfer.effectAllowed = 'move';
  });
  root.addEventListener('dragover', event => {
    if (!dragging) return;
    const target = event.target.closest('[data-practice-group]');
    rows.forEach(row => row.toggleAttribute('data-drop-target', row === target));
    if (!target) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'move';
  });
  root.addEventListener('dragleave', event => {
    const row = event.target.closest('[data-practice-group]');
    if (row && !row.contains(event.relatedTarget)) row.removeAttribute('data-drop-target');
  });
  root.addEventListener('drop', event => {
    const row = event.target.closest('[data-practice-group]');
    if (!row || !dragging) return;
    event.preventDefault();
    move(dragging, row.dataset.practiceGroup, event.target.closest('[data-practice-item]')?.dataset.practiceItem);
    dragEnd();
  });
  root.addEventListener('dragend', dragEnd);
  root.addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    event.preventDefault();
    event.stopPropagation();
    if (dragging) dragEnd();
    else if (selected) select(selected);
    else onDone();
  });

  return {
    open() {
      root.hidden = false;
      title.focus({ preventScroll: true });
    },
    close() {
      dragEnd();
      selected = null;
      updateControls();
      status.textContent = '';
      root.hidden = true;
    },
    dropdownItems: () => [...layout.dropdown],
  };
}
