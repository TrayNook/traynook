import { captureBounds, captureSlots, originalItems, updateCapture } from './capture-stage.mjs';
import { setupPractice } from './practice-layout.mjs';

function enableExample(root, photo) {
  const canvas = root.querySelector('canvas');
  if (typeof canvas.getContext('2d')?.roundRect !== 'function') return;

  const stage = root.querySelector('[data-capture-stage]');
  const launcher = root.querySelector('[data-tray-toggle]');
  const slots = root.querySelector('#capture-slots');
  const caption = root.querySelector('figcaption');
  const layoutPhoto = root.querySelector('[data-layout-photo]');
  const instruction = root.querySelector('[data-instruction]');
  const back = root.querySelector('[data-demo-action="return"]');
  const original = photo.closest('a');
  const labels = JSON.parse(root.dataset.messages);
  const practice = JSON.parse(root.dataset.practiceLabels);
  let view = 'dropdown';

  const layout = setupPractice(root.querySelector('[data-layout-practice]'), practice, {
    onChange() { if (view === 'dropdown') show('dropdown'); },
    onDone() { show('dropdown', 'gear'); },
  });

  function show(next, focus, item) {
    view = next;
    root.dataset.view = next;
    layoutPhoto.hidden = next !== 'layout';
    stage.hidden = caption.hidden = next === 'layout' || next === 'practice';
    if (next === 'practice') {
      layout.open();
      return;
    }
    layout.close();
    if (next === 'layout') {
      layoutPhoto.querySelector('h2').focus({ preventScroll: true });
      return;
    }
    const ids = layout.dropdownItems();
    const open = next === 'dropdown';
    const usePhoto = open && ids.join() === originalItems.join();
    original.style.visibility = usePhoto ? '' : 'hidden';
    canvas.hidden = usePhoto;
    if (!usePhoto) updateCapture(canvas, photo, open, ids);

    launcher.setAttribute('aria-expanded', String(open));
    slots.hidden = !open;
    slots.replaceChildren();
    if (open) {
      for (const { id, x, y, width, height } of captureSlots(ids)) {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'capture-hit';
        button.dataset.slot = id;
        button.title = id === 'settings' ? labels.settings : practice.names[id];
        button.setAttribute('aria-label', button.title);
        button.style.left = `${100 * x / canvas.width}%`;
        button.style.top = `${100 * y / canvas.height}%`;
        button.style.width = `${100 * width / canvas.width}%`;
        button.style.height = `${100 * height / canvas.height}%`;
        slots.append(button);
      }
    }
    back.hidden = next !== 'handoff';
    if (next === 'handoff') instruction.textContent = labels.handoff.replace('{item}', practice.names[item]);
    else if (open) instruction.textContent = ids.length ? labels.open : labels.empty;
    else instruction.textContent = labels.closed;
    if (focus === 'gear') slots.querySelector('[data-slot="settings"]').focus({ preventScroll: true });
    if (focus === 'tray') launcher.focus({ preventScroll: true });
    if (focus === 'back') back.focus({ preventScroll: true });
  }

  launcher.addEventListener('click', event => {
    if (view === 'dropdown') show('closed', 'tray');
    else show('dropdown', event.detail === 0 ? 'gear' : 'tray');
  });
  slots.addEventListener('click', event => {
    const button = event.target.closest('[data-slot]');
    if (!button) return;
    if (button.dataset.slot === 'settings') show('layout');
    else show('handoff', 'back', button.dataset.slot);
  });
  for (const button of root.querySelectorAll('[data-demo-action="practice"], [data-demo-action="arrange"]')) {
    button.addEventListener('click', () => show('practice'));
  }
  root.querySelector('[data-demo-action="back-from-layout"]').addEventListener('click', () => show('dropdown', 'gear'));
  back.addEventListener('click', () => show('dropdown', 'gear'));
  root.addEventListener('keydown', event => {
    if (event.key === 'Escape' && view !== 'practice' && !event.defaultPrevented) {
      event.preventDefault();
      if (view === 'layout') show('dropdown', 'gear');
      else show('closed', 'tray');
    }
  });
  root.addEventListener('pointerdown', event => {
    if (view !== 'dropdown' || event.target.closest('button, a[href]')) return;
    const rect = stage.getBoundingClientRect();
    const x = (event.clientX - rect.left) * canvas.width / rect.width;
    const y = (event.clientY - rect.top) * canvas.height / rect.height;
    const body = captureBounds(layout.dropdownItems());
    const inside = x >= body.x && x <= body.x + body.width && y >= body.y && y <= body.y + body.height;
    if (!inside) show('closed', 'tray');
  });

  original.tabIndex = -1;
  original.setAttribute('aria-hidden', 'true');
  stage.dataset.ready = '';
  root.querySelector('[data-layout-fallback]').hidden = true;
  root.querySelector('[data-example-actions]').hidden = false;
  launcher.hidden = false;
  show('dropdown');
}

for (const root of document.querySelectorAll('[data-product-example]')) {
  const photo = root.querySelector('[data-native-capture] img');
  if (!photo.complete) photo.addEventListener('load', () => enableExample(root, photo), { once: true });
  else if (photo.naturalWidth) enableExample(root, photo);
}
