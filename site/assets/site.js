// Shared by every page: the theme, the menu bar's clock and engraved line, the models sheet, the copy key.
(function(){
  var root = document.documentElement, $ = function(id){ return document.getElementById(id); };

  // Theme: resolved to light or dark on the root, so the icon, the panel and the colours agree. A flip is remembered in this browser only.
  var mq = window.matchMedia ? matchMedia('(prefers-color-scheme: dark)') : null, tbtn = $('theme');
  function saved(){ try { var s = localStorage.getItem('breeze-theme'); return (s === 'light' || s === 'dark') ? s : null; } catch (e) { return null; } }
  function label(t){ if (tbtn) tbtn.setAttribute('aria-label', t === 'dark' ? 'Switch to the light theme' : 'Switch to the dark theme'); }
  function apply(){ var t = saved() || (mq && mq.matches ? 'dark' : 'light'); root.setAttribute('data-theme', t); label(t); }
  if (tbtn) tbtn.addEventListener('click', function(){
    var t = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem('breeze-theme', t); } catch (e) {}
    root.setAttribute('data-theme', t); label(t);
  });
  if (mq && mq.addEventListener) mq.addEventListener('change', apply);
  apply();

  // The bar's engraved line appears once the page has moved under it.
  var top = document.querySelector('.top');
  function onScroll(){ if (top) top.classList.toggle('scrolled', (window.scrollY || root.scrollTop) > 2); }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  // The clock keeps the visitor's time, in the visitor's format. Pages that hang things from the bar listen for the tick.
  var dateEl = $('clockDate'), timeEl = $('clockTime');
  function tick(){
    var d = new Date();
    try {
      if (dateEl) dateEl.textContent = new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric', month: 'short' }).format(d).replace(/,/g, '');
      if (timeEl) timeEl.textContent = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' }).format(d);
    } catch (e) { if (timeEl) timeEl.textContent = d.getHours() + ':' + String(d.getMinutes()).padStart(2, '0'); }
    try { window.dispatchEvent(new CustomEvent('breeze:bar')); } catch (e) {}
  }
  if (timeEl) { tick(); setInterval(tick, 15000); }

  // The models sheet.
  var dlg = $('models');
  if (dlg && dlg.showModal) {
    function openModels(){ dlg.showModal(); var h = $('models-title'); if (h) h.focus({ preventScroll: true }); }
    Array.prototype.forEach.call(document.querySelectorAll('[data-open="models"]'), function(el){
      el.addEventListener('click', function(e){ e.preventDefault(); openModels(); });
    });
    dlg.querySelector('[data-close]').addEventListener('click', function(){ dlg.close(); });
    dlg.addEventListener('click', function(e){ if (e.target === dlg) dlg.close(); });
    if (location.hash === '#models') openModels();
  }

  // 'Here is how' unfolds the first-launch answer where it is a folded question.
  Array.prototype.forEach.call(document.querySelectorAll('[data-open="allow"]'), function(el){
    el.addEventListener('click', function(){ var d = $('allow'); if (d && d.tagName === 'DETAILS') d.setAttribute('open', ''); });
  });

  // Copy the Terminal command.
  var btn = $('copy'), code = $('xattr');
  if (btn && code) btn.addEventListener('click', function(){
    function done(){ btn.textContent = 'Copied'; setTimeout(function(){ btn.textContent = 'Copy'; }, 1500); }
    function fallback(){ var r = document.createRange(); r.selectNodeContents(code); var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r); btn.textContent = 'Selected'; setTimeout(function(){ btn.textContent = 'Copy'; }, 1500); }
    if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(code.textContent).then(done, fallback); } else { fallback(); }
  });
})();
