// Source coordinates in the owner's 532 × 234 dropdown photograph.
export const originalItems = ['blue', 'pink', 'aqua', 'plane'];
const slotWidth = 88;
const launcherX = 260;
const sourceBody = { x: 20, y: 86, width: 480, height: 124 };

export function captureBounds(ids) {
  const width = 40 + slotWidth * (1 + ids.length);
  return { x: launcherX - width / 2, y: sourceBody.y, width, height: sourceBody.height };
}

export function captureSlots(ids) {
  const { x } = captureBounds(ids);
  return ['settings', ...ids].map((id, index) => ({
    id, x: x + 20 + index * slotWidth, y: 114, width: slotWidth, height: 68,
  }));
}

export function updateCapture(canvas, image, open, ids) {
  const ctx = canvas.getContext('2d');
  if (!ctx) return false;
  if (canvas.width !== 532) canvas.width = 532;
  if (canvas.height !== 234) canvas.height = 234;
  ctx.clearRect(0, 0, 532, 234);
  if (!open) {
    // The open popover's pointer first appears on row 62.
    ctx.drawImage(image, 0, 0, 532, 62, 0, 0, 532, 62);
    return true;
  }
  if (ids.length === originalItems.length && ids.every((id, i) => id === originalItems[i])) {
    ctx.drawImage(image, 0, 0);
    return true;
  }

  // Retain the photographed menu bar and its pointer. Leave unseen desktop pixels transparent.
  ctx.drawImage(image, 0, 0, 532, 74, 0, 0, 532, 74);
  ctx.save();
  ctx.beginPath();
  ctx.moveTo(247, 74);
  ctx.lineTo(273, 74);
  ctx.quadraticCurveTo(280, 84, 286, 86);
  ctx.lineTo(234, 86);
  ctx.quadraticCurveTo(240, 84, 247, 74);
  ctx.clip();
  ctx.drawImage(image, 234, 74, 52, 12, 234, 74, 52, 12);
  ctx.restore();

  const bounds = captureBounds(ids);
  const middleX = bounds.x + 92;
  const middleWidth = bounds.width - 92 - 24;
  ctx.save();
  ctx.beginPath();
  ctx.roundRect(bounds.x, bounds.y, bounds.width, bounds.height, 22);
  ctx.clip();
  // Fixed end strips preserve the native gear and corners. Only the center material stretches.
  ctx.drawImage(image, 20, 86, 92, 124, bounds.x, 86, 92, 124);
  ctx.drawImage(image, 112, 86, 364, 124, middleX, 86, middleWidth, 124);
  ctx.drawImage(image, 476, 86, 24, 124, middleX + middleWidth, 86, 24, 124);
  // The clear glass above the icon row supplies its backing when icons move.
  ctx.drawImage(image, 112, 118, 364, 1, middleX, 119, middleWidth, 58);
  for (const slot of captureSlots(ids).slice(1)) {
    const sourceX = 150 + originalItems.indexOf(slot.id) * slotWidth;
    const targetX = slot.x + 22;
    ctx.save();
    ctx.beginPath();
    ctx.roundRect(targetX, 126, 44, 44, 10);
    ctx.clip();
    ctx.drawImage(image, sourceX, 126, 44, 44, targetX, 126, 44, 44);
    ctx.restore();
  }
  ctx.restore();
  return true;
}
