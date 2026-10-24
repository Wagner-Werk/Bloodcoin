import sys
p=sys.argv[1]; s=open(p).read()
def rep(a,b):
    global s
    assert s.count(a)==1,(a[:60],s.count(a)); s=s.replace(a,b)
blank=lambda lbl:f'  <section data-kind="paper" data-label="{lbl}" data-spread-only="1"></section>\n\n'
rep('  <section data-kind="paper" data-label="Colophon" data-id="colophon">', blank('Colophon')+'  <section data-kind="paper" data-label="Colophon" data-id="colophon">')
rep('  <section data-kind="plate" data-label="Plate I">', blank('Plate I')+'  <section data-kind="plate" data-label="Plate I">')
rep('''  const PAGES = [...tpl.content.children].map((s, i) => ({
    kind: s.dataset.kind, label: s.dataset.label, id: s.dataset.id || null,
    cls: s.className, html: s.innerHTML, idx: i
  }));
  const N = PAGES.length;''','''  // spread-only pages are blank versos that keep the plate alone on the last spread; phones skip them
  let fol = 0;
  const ALL = [...tpl.content.children].map((s, i) => {
    const only = !!s.dataset.spreadOnly;
    return { kind: s.dataset.kind, label: s.dataset.label, id: s.dataset.id || null,
      cls: s.className, html: s.innerHTML, idx: i, only, fol: only || !i ? 0 : ++fol };
  });
  let PAGES = ALL, N = ALL.length;''')
rep('''    const page = mode ? visiblePage() : 0;
    mode = newMode;''','''    const seen = mode ? PAGES[visiblePage()] : null;
    mode = newMode;
    PAGES = mode === 'spread' ? ALL : ALL.filter(p => !p.only); N = PAGES.length;
    let page = seen ? PAGES.indexOf(seen) : 0;
    if (page < 0) page = PAGES.findIndex(p => p.idx > seen.idx);''')
rep("    if (p.kind === 'cover' || p.kind === 'marble') { f.innerHTML = p.html; return f; }\n    const num = p.idx; // contents = I",
    "    if (p.kind === 'cover' || p.kind === 'marble') { f.innerHTML = p.html; return f; }\n    if (p.only) { f.className += ' blank'; return f; }\n    const num = p.fol; // first paper page = I")
open(p,'w').write(s)
