// Terminal proses FPGA (hanya baca) untuk halaman Setup. Pakai: <div id="term"></div><script src="/static/term.js"></script>
// Opsi: <div id="term" data-src="fpga,link"> untuk menyaring sumber awal. Memuat dirinya sendiri setelah login terbukti (falcon-ready).
(function(){
  const host = document.getElementById('term');
  if (!host) return;
  const SRC = {fpga:'FPGA', traffic:'TRAFFIC', stack:'STACK', link:'LINK', sistem:'SISTEM'};
  const want = (host.dataset.src || '').split(',').filter(Boolean);
  const active = new Set(want.length ? want : Object.keys(SRC));
  let last = 0, paused = false, rows = [], timer = null, busyHint = false;

  host.innerHTML =
    '<div class="panel term-panel"><h3>Terminal proses <span class="tag ok" id="term-state">langsung</span>' +
    '<span class="term-tools">' +
      '<span id="term-filters"></span>' +
      '<button class="tbtn" id="term-pause">Jeda</button>' +
      '<button class="tbtn" id="term-copy">Salin</button>' +
      '<button class="tbtn" id="term-clear">Bersihkan</button>' +
    '</span></h3>' +
    '<div class="term" id="term-body" role="log" aria-live="polite"></div>' +
    '<div class="term-foot">Hanya baca · tidak ada perintah dari browser · IMSI disamarkan · hanya di memori backend</div></div>';

  const body = host.querySelector('#term-body');
  const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
  const fmt = ts => { const d = new Date(ts*1000); return d.toTimeString().slice(0,8) + '.' + String(d.getMilliseconds()).padStart(3,'0'); };

  const fbox = host.querySelector('#term-filters');
  fbox.innerHTML = Object.keys(SRC).map(k =>
    '<label class="tf"><input type="checkbox" data-k="'+k+'"'+(active.has(k)?' checked':'')+'><span class="s-'+k+'">'+SRC[k]+'</span></label>').join('');
  fbox.addEventListener('change', e => { const k = e.target.dataset.k; e.target.checked ? active.add(k) : active.delete(k); render(true); });

  function line(r){
    return '<div class="tl l-'+r.lvl+'"><span class="tt">'+fmt(r.ts)+'</span><span class="ts s-'+r.src+'">'+(SRC[r.src]||r.src)+'</span><span class="tx">'+esc(r.text)+'</span></div>';
  }
  function render(full){
    const vis = rows.filter(r => active.has(r.src));
    const atEnd = body.scrollTop + body.clientHeight >= body.scrollHeight - 24;
    body.innerHTML = vis.length ? vis.map(line).join('') : '<div class="tl l-info"><span class="tx dim">belum ada proses. Tekan "Muat gateware" atau mulai sumber traffic untuk melihat prosesnya di sini.</span></div>';
    if (!paused && (atEnd || full)) body.scrollTop = body.scrollHeight;
  }
  async function poll(){
    try {
      const r = await fetch('/api/setup/log?since=' + last);
      if (r.status === 401) { location.replace('/login?next=' + encodeURIComponent(location.pathname)); return; }
      const j = await r.json();
      if (j.rows && j.rows.length) {
        rows = rows.concat(j.rows).slice(-(j.cap || 500)); last = j.last;
        if (!paused) render(false);
      }
      host.querySelector('#term-state').textContent = paused ? 'dijeda' : 'langsung';
      host.querySelector('#term-state').className = 'tag ' + (paused ? 'warn' : 'ok');
    } catch (e) {
      host.querySelector('#term-state').textContent = 'terputus'; host.querySelector('#term-state').className = 'tag bad';
    }
  }
  host.querySelector('#term-pause').onclick = e => { paused = !paused; e.target.textContent = paused ? 'Lanjut' : 'Jeda'; if (!paused) render(true); poll(); };
  host.querySelector('#term-copy').onclick = async e => {
    const txt = rows.filter(r => active.has(r.src)).map(r => fmt(r.ts) + ' [' + (SRC[r.src]||r.src) + '] ' + r.text).join('\n');
    try { await navigator.clipboard.writeText(txt); e.target.textContent = 'Tersalin'; } catch (_) { e.target.textContent = 'Gagal'; }
    setTimeout(() => e.target.textContent = 'Salin', 1400);
  };
  host.querySelector('#term-clear').onclick = async () => {
    if (window.FALCON_ROLE !== 'operator') return;
    await fetch('/api/setup/log/clear', {method:'POST'}); rows = []; last = 0; render(true); poll();
  };
  document.addEventListener('falcon-ready', () => {
    if (window.FALCON_ROLE !== 'operator') host.querySelector('#term-clear').style.display = 'none';
    poll(); timer = setInterval(poll, 1000);
  });
})();
