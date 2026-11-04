// Header + navigasi bersama untuk halaman Setup. Pakai: <div id="hdr"></div><script src="/static/nav.js"></script>
(function(){
  const links = [['/','Dashboard'],['/setup/fpga','Setup FPGA'],['/setup/traffic','Setup Traffic']];
  const here = location.pathname.replace(/\/$/,'') || '/';
  const hdr = document.getElementById('hdr');
  hdr.innerHTML = '<header><img class="logo" src="/static/falcon-logo-64.png" width="40" height="40" alt="FALCON">' +
    '<div class="brand"><h1>FALCON <span>Setup</span></h1><small>Arah Karya Sinergi · GTP-U DPI Engine</small></div>' +
    '<nav>' + links.map(([h,t]) => '<a href="'+h+'"'+(h===here?' class="on"':'')+'>'+t+'</a>').join('') +
    '<span class="who" id="who"></span><button id="out">Keluar</button></nav></header>';
  fetch('/api/me').then(r=>r.json()).then(j=>{
    if (!j.logged_in) { location.replace('/login?next='+encodeURIComponent(here)); return; }
    document.getElementById('who').textContent = j.user + ' · ' + j.role;
    window.FALCON_ROLE = j.role;
    document.dispatchEvent(new Event('falcon-ready'));
  });
  document.getElementById('out').onclick = async () => { await fetch('/api/logout',{method:'POST'}); location.replace('/login'); };
})();
