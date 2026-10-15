#!/usr/bin/env python3
"""Assembles the live panel (panel.css/html/js, with the SF Symbol masks in sym/ inlined) into ../index.html between its
panel markers, and writes a 372x541 test harness per theme for diffing against the app's own 2x render.

    python3 site/src/build.py --site [harness-dir]

Harness renders at 2x with headless Chrome: --force-device-scale-factor=2 --window-size=800,1120 --screenshot=out.png test-light.html
Compare with `swift site/src/diff.swift out.png app-render.png diff.png`; re-export symbols with `swift site/src/symbols.swift site/src/sym`."""
import re, sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.join(os.path.dirname(HERE), 'index.html')
OUT = next((a for a in sys.argv[1:] if not a.startswith('--')), '/tmp')
import base64
css = open(os.path.join(HERE, 'panel.css')).read()
SYM = os.path.join(HERE, 'sym')
def inline(m):
    data = base64.b64encode(open(os.path.join(SYM, m.group(1) + '.png'), 'rb').read()).decode()
    return 'url(data:image/png;base64,' + data + ')'
css = re.sub(r'url\(assets/sym/([a-z]+)\.png\)', inline, css)
html = open(os.path.join(HERE, 'panel.html')).read()
js = open(os.path.join(HERE, 'panel.js')).read()
site = open(SITE).read()
sheet = open(os.path.join(os.path.dirname(HERE), 'assets', 'site.css')).read()
tokens = sheet[sheet.index(':root{'):sheet.index('*{box-sizing:border-box}')] + ':root{--stone:url(assets/stone-light.jpg)}:root[data-theme="dark"]{--stone:url(assets/stone-dark.jpg)}'

for theme in ('light', 'dark'):
    page = ('<!doctype html><html lang="en" data-theme="%s"><head><meta charset="utf-8"><style>%s%s\nbody{margin:0;background:#fff}</style></head>'
            '<body>%s<script>%s</script><script>document.title = JSON.stringify(Array.prototype.map.call(document.querySelectorAll(".bz,.bz-head,.bz-hero,.bz-unit,.bz-temp,#bzWhole,.bz-col,.bz-eco,.bz-slider,.bz-track,.bz-range,.bz-tiles,.bz-tile,.bz-foot"), function(e){ var r = e.getBoundingClientRect(); return [e.className || e.id, Math.round(r.left*10)/10, Math.round(r.top*10)/10, Math.round(r.width*10)/10, Math.round(r.height*10)/10]; }));</script></body></html>') % (theme, tokens, css, html, js)
    open(os.path.join(OUT, 'test-%s.html' % theme), 'w').write(page)

if '--site' in sys.argv:
    def put(s, a, b, body):
        i, j = s.index(a) + len(a), s.index(b)
        return s[:i] + '\n' + body + s[j:]
    site = put(site, '/* panel:css */', '/* /panel:css */', css)
    site = put(site, '<!-- panel:html -->', '<!-- /panel:html -->', html)
    site = put(site, '// panel:js', '// /panel:js', js)
    open(SITE, 'w').write(site)
    print('site updated')
print('harness written')
