// The panel's behaviour, ported from DeviceStore/ControlPanelView: the same state, the same rules.
window.BreezePanel = (function(){
  var $ = function(id){ return document.getElementById(id); };
  var root = $('bz'); if (!root) return null;
  var S = { power: true, temp: 22, mode: 'cool', fan: 102, flash: false, swing: 'both', eco: false };
  var MODES = [['auto','Auto','s-auto'],['cool','Cool','s-snowflake'],['dry','Dry','s-dry'],['heat','Heat','s-sun'],['fan','Fan','s-fan']];
  var FANS = [[102,'Auto'],[40,'Low'],[60,'Medium'],[80,'High']];
  var SWINGS = [['off','Off'],['vertical','Vertical'],['horizontal','Horizontal'],['both','Both']];
  var MIN = 16, MAX = 30, listeners = [];
  function find(list, key){ for (var i = 0; i < list.length; i++) if (list[i][0] === key) return list[i]; return list[0]; }
  function isDark(){ return document.documentElement.getAttribute('data-theme') === 'dark'; }

  // Status item title, as DeviceStore.updateTitle builds it.
  function title(){ if (!S.power) return 'Off'; return (S.temp % 1 ? S.temp.toFixed(1) : String(S.temp)) + '°'; }

  var lastWhole = 22;
  function render(){
    root.classList.toggle('off', !S.power);
    root.classList.toggle('half', S.temp % 1 !== 0);
    root.style.setProperty('--air', S.mode === 'heat' ? 'var(--heat)' : 'var(--cool)');
    var whole = Math.floor(S.temp), w = $('bzWhole');
    if (whole !== lastWhole) {
      w.style.setProperty('--dir', whole > lastWhole ? 1 : -1);
      w.classList.remove('roll'); void w.offsetWidth; w.classList.add('roll');
      lastWhole = whole;
    }
    w.textContent = whole;
    var track = $('bzTrack');
    track.style.setProperty('--f', (S.temp - MIN) / (MAX - MIN));
    track.setAttribute('aria-valuenow', S.temp); track.setAttribute('aria-valuetext', S.temp + ' degrees');
    var p = $('bzPower'); p.classList.toggle('on', S.power); p.setAttribute('aria-pressed', S.power); p.setAttribute('aria-label', S.power ? 'Turn off' : 'Turn on'); p.title = p.getAttribute('aria-label');
    var m = find(MODES, S.mode); $('bzModeVal').textContent = m[1]; $('bzModeIcon').className = 'sym ' + m[2];
    $('bzFanVal').textContent = find(FANS, S.fan)[1];
    $('bzSwingVal').textContent = find(SWINGS, S.swing)[1];
    $('bzFlashVal').textContent = S.flash ? 'On' : 'Off'; $('bzFlashDot').classList.toggle('on', S.flash); $('bzFlash').setAttribute('aria-pressed', S.flash);
    $('bzEco').classList.toggle('on', S.eco); $('bzEcoSw').classList.toggle('on', S.eco); $('bzEcoSw').setAttribute('aria-checked', S.eco);
    var watts = $('bzWatts'); watts.hidden = !S.power; watts.textContent = '· ' + (S.flash ? '1.4 kW' : (S.eco ? '540 W' : '820 W'));
    fitValues();
    for (var i = 0; i < listeners.length; i++) listeners[i](S, title());
  }
  // TileBody's minimumScaleFactor(0.75): a long value shrinks to fit, never wraps.
  function fitValues(){
    var vals = root.querySelectorAll('.bz-val');
    for (var i = 0; i < vals.length; i++) {
      var el = vals[i]; el.style.fontSize = '';
      var avail = el.parentNode.clientWidth - 26, need = el.scrollWidth;
      if (need > avail) el.style.fontSize = Math.max(11.25, 15 * avail / need) + 'px';
    }
  }
  function setTemp(t){ S.temp = Math.min(MAX, Math.max(MIN, Math.round(t * 2) / 2)); render(); }

  // Air: AirflowView's canvas, line for line. Fan speed sets pace and density; swing sweeps and tilts the field.
  var canvas = $('bzAir'), ctx = canvas.getContext('2d'), dpr = Math.min(3, window.devicePixelRatio || 1), W = 300, H = 76;
  canvas.width = W * dpr; canvas.height = H * dpr;
  var t0 = Math.random() * 1000, last = 0, raf = 0, visible = true, shown = true;
  function tint(){ return S.mode === 'heat' ? (isDark() ? '#e8907c' : '#b5593b') : (isDark() ? '#a9c4da' : '#5f88a8'); }
  function rgba(hex, a){ var v = parseInt(hex.slice(1), 16); return 'rgba(' + (v >> 16) + ',' + ((v >> 8) & 255) + ',' + (v & 255) + ',' + a + ')'; }
  function draw(now){
    raf = requestAnimationFrame(draw);
    if (!S.power || !visible || !shown) return;
    if (now - last < 1000 / 30) return; last = now;
    var t = t0 + now / 1000, c = tint();
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, W, H);
    var speed = S.fan === 102 ? 0.6 : Math.min(Math.max(S.fan, 20), 100) / 100;
    var horizontal = S.swing === 'horizontal' || S.swing === 'both', vertical = S.swing === 'vertical' || S.swing === 'both';
    var sweep = horizontal ? Math.sin(t * 0.8) * 42 : 0;
    var tilt = vertical ? 0.5 + 0.5 * Math.sin(t * 0.65) : 0.55;
    var reach = H * (0.6 + 0.4 * tilt), spreadScale = 0.45 + 0.9 * tilt;
    var lines = 9, fieldWidth = 186, left = (W - fieldWidth) / 2;
    var alpha = 0.3 + 0.3 * speed, dashOn = 14 + 10 * speed, dashOff = 11 - 4 * speed, lineWidth = 3.5 + 2.5 * speed, flowRate = 28 + 50 * speed;
    ctx.lineCap = 'round'; ctx.lineWidth = lineWidth; ctx.setLineDash([dashOn, dashOff]);
    var g = ctx.createLinearGradient(0, 0, 0, reach);
    g.addColorStop(0, rgba(c, alpha)); g.addColorStop(0.5, rgba(c, alpha * 0.4)); g.addColorStop(1, rgba(c, 0));
    ctx.strokeStyle = g;
    for (var i = 0; i < lines; i++) {
      var fi = i / (lines - 1), x0 = left + fi * fieldWidth;
      var sway = Math.sin(t * 1.5 * (0.6 + speed) + i * 0.9) * 5;
      var spread = (fi - 0.5) * 44 * spreadScale;
      var endX = x0 + spread + sway + sweep, c1x = x0 + sweep * 0.25 + sway * 0.5, c2x = x0 + spread * 0.7 + sweep * 0.7 - sway;
      ctx.lineDashOffset = -t * flowRate + i * 7;
      ctx.beginPath(); ctx.moveTo(x0, 0); ctx.bezierCurveTo(c1x, reach * 0.35, c2x, reach * 0.7, endX, reach); ctx.stroke();
    }
  }
  raf = requestAnimationFrame(draw);
  document.addEventListener('visibilitychange', function(){ visible = !document.hidden; });

  // Menus: the tile's NSMenu, opened under the tile.
  var menu = $('bzMenu'), menuFor = null;
  function closeMenu(){ if (!menuFor) return; menu.hidden = true; menuFor.setAttribute('aria-expanded', 'false'); var b = menuFor; menuFor = null; b.focus({ preventScroll: true }); }
  function openMenu(tile, items){
    if (menuFor === tile) { closeMenu(); return; }
    closeMenu();
    menu.innerHTML = '';
    items.forEach(function(it){
      if (it === '-') { menu.appendChild(document.createElement('hr')); return; }
      var b = document.createElement('button'); b.type = 'button'; b.setAttribute('role', 'menuitem');
      if (it.icon) { var ic = document.createElement('i'); ic.className = 'sym ' + it.icon; ic.setAttribute('aria-hidden', 'true'); b.appendChild(ic); }
      b.appendChild(document.createTextNode(it.label));
      b.addEventListener('click', function(){ closeMenu(); it.run(); });
      menu.appendChild(b);
    });
    menu.style.left = tile.offsetLeft + 'px'; menu.style.top = (tile.offsetTop + tile.offsetHeight + 4) + 'px';
    menu.hidden = false; menuFor = tile; tile.setAttribute('aria-expanded', 'true');
    var first = menu.querySelector('button'); if (first) first.focus({ preventScroll: true });
  }
  document.addEventListener('pointerdown', function(e){ if (menuFor && !menu.contains(e.target) && !menuFor.contains(e.target)) closeMenu(); });
  document.addEventListener('keydown', function(e){
    if (!menuFor) return;
    var items = Array.prototype.slice.call(menu.querySelectorAll('button')), i = items.indexOf(document.activeElement);
    if (e.key === 'Escape') { closeMenu(); e.preventDefault(); }
    if (e.key === 'ArrowDown') { items[(i + 1) % items.length].focus(); e.preventDefault(); }
    if (e.key === 'ArrowUp') { items[(i - 1 + items.length) % items.length].focus(); e.preventDefault(); }
  });

  $('bzPower').addEventListener('click', function(){ S.power = !S.power; render(); });
  $('bzMinus').addEventListener('click', function(){ setTemp(S.temp - 0.5); });
  $('bzPlus').addEventListener('click', function(){ setTemp(S.temp + 0.5); });
  $('bzEcoSw').addEventListener('click', function(){ S.eco = !S.eco; render(); });
  $('bzFlash').addEventListener('click', function(){ S.flash = !S.flash; render(); });
  $('bzMode').addEventListener('click', function(){ openMenu(this, MODES.map(function(m){ return { label: m[1], icon: m[2], run: function(){ S.mode = m[0]; render(); } }; })); });
  $('bzFan').addEventListener('click', function(){ openMenu(this, FANS.map(function(f){ return { label: f[1], run: function(){ S.fan = f[0]; render(); } }; })); });
  $('bzSwing').addEventListener('click', function(){ openMenu(this, SWINGS.map(function(s){ return { label: s[1], run: function(){ S.swing = s[0]; render(); } }; }).concat(['-', { label: 'Breeze Away', run: function(){} }, { label: 'Breezeless', run: function(){} }])); });

  // The slider: TemperatureSlider's drag, snapping to half degrees.
  var track = $('bzTrack'), dragging = false;
  function fromEvent(e){ var r = track.getBoundingClientRect(); var k = r.width / track.clientWidth; var x = (e.clientX - r.left) / k; var f = Math.min(1, Math.max(0, (x - 15) / (track.clientWidth - 30))); setTemp(MIN + f * (MAX - MIN)); }
  track.addEventListener('pointerdown', function(e){ dragging = true; root.classList.add('dragging'); track.setPointerCapture(e.pointerId); fromEvent(e); });
  track.addEventListener('pointermove', function(e){ if (dragging) fromEvent(e); });
  function endDrag(){ dragging = false; root.classList.remove('dragging'); }
  track.addEventListener('pointerup', endDrag); track.addEventListener('pointercancel', endDrag);
  track.addEventListener('keydown', function(e){
    if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') { setTemp(S.temp - 0.5); e.preventDefault(); }
    if (e.key === 'ArrowRight' || e.key === 'ArrowUp') { setTemp(S.temp + 0.5); e.preventDefault(); }
  });

  render();
  return { state: S, set: function(p){ for (var k in p) S[k] = p[k]; render(); }, onChange: function(fn){ listeners.push(fn); fn(S, title()); }, title: title, refit: fitValues, visible: function(v){ shown = v; } };
})();
