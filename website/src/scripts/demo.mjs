import { INITIAL_ITEMS, moveItem } from './demo-state.mjs';

const demo = document.querySelector('#interactive-demo');
const launcher = document.querySelector('#tray-launcher');
const dropdown = document.querySelector('#native-dropdown');
const settings = document.querySelector('#native-settings');
const help = document.querySelector('#layout-help');
const handoff = document.querySelector('#handoff-note');
const copy = JSON.parse(document.querySelector('#demo-copy').textContent);
const assets = demo.dataset.assets;
const groupNames = { menu: copy.menu, dropdown: copy.dropdown, hidden: copy.hidden };
const itemName = item => copy.itemNames[item.id];
const message = (key, values = {}) => copy[key].replace(/\{(\w+)\}/g, (_, name) => values[name]);
let items = [...INITIAL_ITEMS];
let selected = null;
let dragging = null;
let activated = null;

function announce(message) {
  document.querySelector('#demo-announcement').textContent = message;
}

function iconButton(item, editing = false, inMenuBar = false) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = inMenuBar ? 'menu-icon' : 'native-button';
  button.dataset.item = item.id;
  button.title = itemName(item);
  button.setAttribute('aria-label', editing ? `${itemName(item)}, ${groupNames[item.group]}` : itemName(item));
  const image = document.createElement('img');
  image.src = `${assets}${item.icon}`;
  image.width = image.height = inMenuBar ? 18 : 26;
  image.alt = '';
  image.className = 'icon';
  if (inMenuBar) button.append(image);
  else {
    const icon = document.createElement('span');
    icon.className = 'sample-icon';
    icon.dataset.tone = item.tone;
    icon.append(image);
    button.append(icon);
  }
  if (editing) {
    button.draggable = true;
    button.setAttribute('aria-pressed', String(selected === item.id));
    button.setAttribute('aria-describedby', 'layout-help');
  }
  return button;
}

function renderChrome() {
  const visible = items.filter(item => item.group === 'menu' || item.id === activated);
  document.querySelector('#visible-items').replaceChildren(...visible.map(item => iconButton(item, false, true)));
  const gear = document.createElement('button');
  gear.type = 'button';
  gear.className = 'native-button';
  gear.dataset.openSettings = '';
  gear.title = copy.openSettings;
  gear.setAttribute('aria-label', copy.openSettings);
  const image = document.createElement('img');
  image.src = `${assets}settings.svg`;
  image.width = image.height = 21;
  image.alt = '';
  image.className = 'icon';
  gear.append(image);
  const dropdownItems = items.filter(item => item.group === 'dropdown');
  const columns = Math.min(5, dropdownItems.length + 1);
  dropdown.style.width = `${columns * 44 + 20}px`;
  dropdown.style.setProperty('--columns', columns);
  document.querySelector('#dropdown-items').replaceChildren(gear, ...dropdownItems.map(item => iconButton(item)));
  const empty = dropdownItems.length === 0;
  document.querySelector('#empty-guidance').hidden = !empty;
  if (empty) dropdown.style.width = '180px';
}

function renderSettings(focusId = null) {
  for (const lane of settings.querySelectorAll('[data-items]')) {
    lane.replaceChildren(...items.filter(item => item.group === lane.dataset.items).map(item => iconButton(item, true)));
  }
  settings.toggleAttribute('data-selecting', selected !== null);
  settings.querySelectorAll('[data-destination]').forEach(button => button.disabled = selected === null);
  const item = items.find(item => item.id === selected);
  help.textContent = item ? message('selected', { name: itemName(item) }) : copy.help;
  if (focusId) settings.querySelector(`[data-item="${focusId}"]`)?.focus({ preventScroll: true });
}

function setDropdown(open, keyboard = false) {
  dropdown.hidden = !open;
  launcher.setAttribute('aria-expanded', String(open));
  if (open) {
    activated = null;
    handoff.hidden = true;
    renderChrome();
    if (keyboard) dropdown.querySelector('button').focus({ preventScroll: true });
  }
}

function openSettings() {
  setDropdown(false);
  activated = null;
  handoff.hidden = true;
  selected = null;
  settings.hidden = false;
  renderChrome();
  renderSettings();
  document.querySelector('#close-settings').focus({ preventScroll: true });
}

function closeSettings() {
  settings.hidden = true;
  selected = null;
  launcher.focus({ preventScroll: true });
}

function commitMove(id, group, before = null) {
  const next = moveItem(items, id, group, before);
  if (next === items) return;
  items = next;
  selected = null;
  dragging = null;
  clearDropTargets();
  renderChrome();
  renderSettings(id);
  announce(message('moved', { name: itemName(items.find(item => item.id === id)), group: groupNames[group] }));
}

function clearDropTargets() {
  settings.querySelectorAll('[data-drop-active]').forEach(lane => lane.removeAttribute('data-drop-active'));
}

launcher.addEventListener('click', event => {
  if (!settings.hidden) closeSettings();
  setDropdown(dropdown.hidden, event.detail === 0);
});
document.querySelector('#try-layout').addEventListener('click', openSettings);
document.querySelector('#close-settings').addEventListener('click', closeSettings);
document.querySelector('#back-to-dropdown').addEventListener('click', () => {
  setDropdown(true, true);
});
document.querySelector('#reset-demo').addEventListener('click', () => {
  items = [...INITIAL_ITEMS];
  selected = activated = null;
  renderChrome();
  renderSettings();
  announce(copy.resetAnnouncement);
});

demo.addEventListener('click', event => {
  if (event.target.closest('[data-open-settings]')) return openSettings();
  const destination = event.target.closest('[data-destination]');
  if (destination && selected) return commitMove(selected, destination.dataset.destination);
  const button = event.target.closest('[data-item]');
  if (!button) return;
  const item = items.find(item => item.id === button.dataset.item);
  if (!item) return;
  if (settings.contains(button)) {
    selected = selected === item.id ? null : item.id;
    renderSettings(item.id);
    announce(help.textContent);
  } else {
    setDropdown(false);
    activated = item.group === 'menu' ? null : item.id;
    renderChrome();
    document.querySelector('#handoff-text').textContent = message('handoff', { name: itemName(item) });
    handoff.hidden = false;
    document.querySelector('#back-to-dropdown').focus({ preventScroll: true });
    announce(message('activated', { name: itemName(item) }));
  }
});

demo.addEventListener('pointerdown', event => {
  if (!dropdown.hidden && !dropdown.contains(event.target) && !launcher.contains(event.target)) setDropdown(false);
});
demo.addEventListener('keydown', event => {
  if (event.key !== 'Escape') return;
  event.preventDefault();
  if (dragging || selected) {
    const id = dragging || selected;
    dragging = selected = null;
    clearDropTargets();
    renderSettings(id);
    announce(copy.cancelled);
  } else if (!settings.hidden) closeSettings();
  else {
    setDropdown(false);
    activated = null;
    handoff.hidden = true;
    renderChrome();
    launcher.focus({ preventScroll: true });
  }
});

settings.addEventListener('dragstart', event => {
  const button = event.target.closest('[data-item]');
  if (!button) return;
  dragging = button.dataset.item;
  event.dataTransfer.setData('text/plain', dragging);
  event.dataTransfer.effectAllowed = 'move';
});
settings.addEventListener('dragover', event => {
  const lane = event.target.closest('[data-group]');
  if (!dragging || !lane) return;
  event.preventDefault();
  event.dataTransfer.dropEffect = 'move';
  clearDropTargets();
  lane.setAttribute('data-drop-active', '');
});
settings.addEventListener('dragleave', event => {
  const lane = event.target.closest('[data-group]');
  if (lane && !lane.contains(event.relatedTarget)) lane.removeAttribute('data-drop-active');
});
settings.addEventListener('drop', event => {
  const lane = event.target.closest('[data-group]');
  if (!dragging || !lane) return;
  event.preventDefault();
  const target = event.target.closest('[data-item]');
  commitMove(dragging, lane.dataset.group, target?.dataset.item || null);
});
settings.addEventListener('dragend', () => {
  dragging = null;
  clearDropTargets();
});

renderChrome();
renderSettings();
