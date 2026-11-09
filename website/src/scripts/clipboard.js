document.querySelectorAll('[data-copy-command]').forEach(button => {
  const code = document.getElementById(button.getAttribute('aria-controls'));
  const status = button.closest('[data-install-command]').querySelector('[data-copy-feedback]');
  let resetTimer;
  button.hidden = false;
  button.addEventListener('click', async () => {
    clearTimeout(resetTimer);
    delete button.dataset.copyState;
    button.disabled = true;
    status.textContent = '';
    try {
      await navigator.clipboard.writeText(code.textContent);
      button.dataset.copyState = 'copied';
      status.textContent = button.dataset.copied;
      resetTimer = setTimeout(() => {
        delete button.dataset.copyState;
        status.textContent = '';
      }, 2500);
    } catch {
      code.parentElement.focus();
      const range = document.createRange();
      range.selectNodeContents(code);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      status.textContent = button.dataset.copyFailed;
    } finally {
      button.disabled = false;
    }
  });
});
