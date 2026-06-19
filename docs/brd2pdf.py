#!/usr/bin/env python3
"""Render BRD markdown -> PDF dengan COVER AKS (Hermes Dashboard + digital wiring).
Usage: python3 brd2pdf.py BRD.md OUTPUT.pdf "KICKER" "TITLE_HTML" "SUBTITLE" "COLLAB"
Portrait A4. Cover page 1, lalu body BRD. weasyprint offline -> logo file lokal.
"""
import sys, os
from markdown_it import MarkdownIt
from weasyprint import HTML

src, out = sys.argv[1], sys.argv[2]
kicker   = sys.argv[3] if len(sys.argv) > 3 else "BUSINESS REQUIREMENTS"
title    = sys.argv[4] if len(sys.argv) > 4 else "Dokumen"
subtitle = sys.argv[5] if len(sys.argv) > 5 else ""
collab   = sys.argv[6] if len(sys.argv) > 6 else ""
logo     = os.path.join(os.path.dirname(os.path.abspath(out)), "assets", "arah-icon-wh.png")
logo_uri = "file://" + logo

md = MarkdownIt("commonmark", {"html": True}).enable("table").enable("strikethrough")
with open(src, encoding="utf-8") as f:
    body = md.render(f.read())

# ---- COVER (A4 portrait, AKS digital wiring) ----
cover = f"""
<div class="cover">
  <svg class="cv-wires" width="794" height="1123" viewBox="0 0 794 1123" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg">
    <g fill="none" stroke="#48CAE4">
      <path d="M-30 330 C 200 330, 360 240, 824 170" stroke-width="3" opacity="0.8"/>
      <path d="M-30 360 C 200 360, 380 310, 824 260" stroke-width="1.6" opacity="0.55"/>
      <path d="M-30 400 C 220 400, 420 410, 824 380" stroke-width="3.5" opacity="0.9"/>
      <path d="M-30 440 C 200 440, 400 500, 824 520" stroke-width="1.4" opacity="0.45"/>
      <path d="M-30 470 C 230 470, 440 560, 824 600" stroke-width="2.6" opacity="0.7"/>
    </g>
    <g fill="none" stroke="#9be8f7">
      <path d="M-30 370 C 220 370, 420 330, 824 300" stroke-width="1.3" opacity="0.9"/>
      <path d="M-30 430 C 220 430, 440 470, 824 500" stroke-width="1.3" opacity="0.75"/>
    </g>
    <g fill="none" stroke="#ffffff">
      <path d="M-30 390 C 150 390, 280 390, 420 380" stroke-width="1.6" opacity="0.7"/>
    </g>
  </svg>
  <div class="cv-inner">
    <div class="cv-brand">
      <img src="{logo_uri}" alt="Arah"/>
      <div class="cv-bt">Arah Karya Sinergi<small>AKS &middot; Simply More.</small></div>
    </div>
    <div class="cv-mid">
      <span class="cv-kick">{kicker}</span>
      <div class="cv-title">{title}</div>
      <div class="cv-sub">{subtitle}</div>
      <div class="cv-tag">Architectural Precision in Digital Era.</div>
    </div>
    <div class="cv-rule"></div>
    <div class="cv-meta">
      <div>
        <div class="cv-prep">Disiapkan oleh <b>Arah Karya Sinergi (AKS)</b></div>
        <div class="cv-collab">{collab}</div>
      </div>
      <div class="cv-stamp"><span class="cv-dot">&#9679;</span> Topik 4865 &middot; FPGA<br>Juni 2026 &middot; v1.0</div>
    </div>
  </div>
</div>
"""

css = """
@page { size: A4; margin: 0; }
@page content { margin: 1.8cm 1.6cm; @bottom-center { content: "Arah Karya Sinergi (AKS) — BRD FPGA   ·   " counter(page); font-size:8pt; color:#8a97a8; } }
* { box-sizing: border-box; }
body { font-family:'DejaVu Sans',sans-serif; font-size:9.5pt; line-height:1.5; color:#1a2230; margin:0; }

/* cover */
.cover{ width:794px; height:1123px; background:#0B1B3D; color:#fff; position:relative; overflow:hidden; page-break-after:always; }
.cover::before{ content:""; position:absolute; inset:0; z-index:0;
  background-image:linear-gradient(rgba(72,202,228,.04) 1px,transparent 1px),linear-gradient(90deg,rgba(72,202,228,.04) 1px,transparent 1px);
  background-size:42px 42px; }
.cover::after{ content:""; position:absolute; left:0; top:0; bottom:0; width:9px; background:linear-gradient(180deg,#48CAE4,#16C79A,#0F3460); }
.cv-wires{ position:absolute; left:0; top:0; width:794px; height:1123px; z-index:1; }
.cv-inner{ position:relative; z-index:2; height:100%; padding:70px 64px; display:flex; flex-direction:column; }
.cv-brand{ display:flex; align-items:center; gap:14px; }
.cv-brand img{ width:50px !important; height:50px !important; object-fit:contain; }
.cv-bt{ font-size:16px; font-weight:800; letter-spacing:.5px; }
.cv-bt small{ display:block; font-size:9.5px; font-weight:500; color:#48CAE4; letter-spacing:2.5px; text-transform:uppercase; margin-top:3px; }
.cv-mid{ margin-top:auto; margin-bottom:auto; position:relative; }
.cv-kick{ display:inline-block; color:#0B1B3D; background:#48CAE4; font-size:11px; font-weight:800; letter-spacing:3px; text-transform:uppercase; padding:6px 13px; border-radius:6px; }
.cv-title{ font-size:40px; font-weight:800; line-height:1.12; margin-top:22px; letter-spacing:-1px; }
.cv-accent{ color:#48CAE4; }
.cv-sub{ font-size:14px; color:#cdd9e6; margin-top:20px; max-width:88%; line-height:1.6; background:rgba(11,27,61,0.72); padding:12px 16px 12px 0; display:inline-block; }
.cv-tag{ font-size:11px; color:#48CAE4; font-weight:600; letter-spacing:1px; margin-top:14px;
  position:relative; z-index:3; background:#0B1B3D; display:inline-block; padding:4px 10px 4px 0; }
.cv-rule{ height:1px; background:rgba(255,255,255,.14); margin:34px 0 20px; position:relative; z-index:3; }
.cv-meta{ display:flex; justify-content:space-between; align-items:flex-end; font-size:11px;
  position:relative; z-index:3; background:#0B1B3D; padding:14px 0 4px; box-shadow:0 -10px 16px 6px #0B1B3D; }
.cv-prep{ color:#aebccd; } .cv-prep b{ color:#fff; }
.cv-collab{ color:#48CAE4; font-weight:700; margin-top:5px; }
.cv-stamp{ text-align:right; color:#aebccd; font-family:'DejaVu Sans Mono',monospace; font-size:10px; line-height:1.7; }
.cv-dot{ color:#48CAE4; }

/* body */
.content{ page: content; }
.content h1{ font-size:19pt; color:#0B1B3D; border-bottom:3px solid #48CAE4; padding-bottom:6px; margin:0 0 4px; }
.content h2{ font-size:13.5pt; color:#0B1B3D; border-bottom:1px solid #dde4ec; padding-bottom:3px; margin-top:20px; }
.content h3{ font-size:11pt; color:#16213e; margin-top:14px; }
.content table{ border-collapse:collapse; width:100%; margin:9px 0; font-size:8.3pt; }
.content th{ background:#0B1B3D; color:#fff; text-align:left; padding:5px 7px; }
.content td{ border:1px solid #d3dae3; padding:4px 7px; vertical-align:top; }
.content tr:nth-child(even) td{ background:#f5f8fb; }
.content code{ background:#eaf6fb; color:#0a6e8a; padding:1px 4px; border-radius:3px; font-family:'DejaVu Sans Mono',monospace; font-size:8.3pt; }
.content pre{ background:#0B1B3D; color:#dfe9f2; padding:11px; border-radius:6px; font-size:7pt; line-height:1.35; overflow-x:auto; }
.content pre code{ background:none; color:#dfe9f2; padding:0; }
.content blockquote{ border-left:4px solid #48CAE4; margin:9px 0; padding:5px 13px; background:#f0fafd; color:#3a4655; }
.content a{ color:#0B1B3D; }
.content strong{ color:#0B1B3D; }
.content hr{ border:none; border-top:1px solid #d3dae3; margin:16px 0; }
.content ul,.content ol{ margin:5px 0; padding-left:20px; } .content li{ margin:2px 0; }
"""

html = f"<html><head><meta charset='utf-8'><style>{css}</style></head><body>{cover}<div class='content'>{body}</div></body></html>"
HTML(string=html, base_url=os.path.dirname(os.path.abspath(out))).write_pdf(out)
print("OK ->", out)
