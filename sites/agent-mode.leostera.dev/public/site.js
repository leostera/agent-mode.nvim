// Set it up with your agent: copy the prompt, and say so.
for (const button of document.querySelectorAll('[data-copy]')) {
  const toast = button.parentElement.querySelector('.copy-toast');
  let timer;
  button.addEventListener('click', async () => {
    const text = button.dataset.copy;
    let copied = false;
    try {
      await navigator.clipboard.writeText(text);
      copied = true;
    } catch {
      const field = Object.assign(document.createElement('textarea'), { value: text });
      field.style.cssText = 'position:fixed;left:-9999px;opacity:0';
      document.body.append(field);
      field.select();
      copied = document.execCommand('copy');
      field.remove();
    }
    toast.textContent = copied ? 'Prompt copied: paste it into your agent' : 'Couldn’t copy. Please try again.';
    toast.hidden = false;
    clearTimeout(timer);
    timer = setTimeout(() => (toast.hidden = true), 3000);
  });
}
