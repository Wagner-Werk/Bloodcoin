S='/tmp/claude-0/-home-user-bloodcoin/4d004a14-3986-5f95-8aca-1c599f112a6f/scratchpad'
s=open(S+'/prod/v-6.html').read()
def rep(a,b):
    global s
    assert s.count(a)==1,(a[:70],s.count(a)); s=s.replace(a,b)
# page title above the book, spread counter stays below
rep('<div class="ribbon" aria-hidden="true"></div>','')
rep('.single .clip{overflow:hidden; width:var(--pw); height:calc(var(--ph) + 60px); padding-top:0}','.single .clip{overflow:hidden; width:var(--pw); height:calc(var(--ph) + 8px); padding-top:0}')
rep('<main class="stage" id="stage" aria-label="Bloodcoin, a book in eight leaves">','<main class="stage" id="stage" aria-label="Bloodcoin, a book in eight leaves">\n<div class="pg-title" aria-live="polite"><span id="where">Bloodcoin</span></div>')
rep('<div class="where" aria-live="polite"><span class="c" id="where">Bloodcoin</span><span class="h" id="hint">','<div class="where"><span class="h" id="hint">')
rep('</style>\n</head>','''
.tight .pg-in{font-size:.95em;gap:.5em}
.side{overflow-y:auto;scrollbar-width:none}
.pg-title{position:absolute;left:0;right:0;z-index:4;top:calc(50% - var(--ph) / 2 - 30px);text-align:center;padding:0 16px;font:italic 19px/1.2 var(--f-italic);color:#e6d3a8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
/* desktop: arrows sit left and right of the book */
@media (max-width:600px){.banner{font-size:10.5px;padding-block:5px;line-height:1.35}.controls{padding-block:4px 8px}.nav{width:40px;height:40px}}
.single .pg-title{top:calc(50% - var(--ph) / 2 - 32px)}
.stage>.nav{position:absolute;top:50%;transform:translateY(-50%);z-index:5}
.stage>#prev{left:calc(50% - var(--pw) - 60px)}.stage>#next{right:calc(50% - var(--pw) - 60px)}
.side.l{left:max(16px,calc(50% - var(--pw) - 290px))}.side.r{right:max(16px,calc(50% - var(--pw) - 290px))}
</style>
</head>''')
rep("const side = W >= 1100 ? 472 : 0;","const side = W >= 1100 ? 548 : 0;")
rep('<section data-kind="paper" data-label="V. The trace" data-id="trace">','<section data-kind="paper" data-label="V. The trace" data-id="trace" class="tight">')
rep("const availH = Math.max(380, H - (m === 'single' ? 214 : W < 1100 ? 184 : 160));","const availH = Math.max(300, stage.clientHeight - (m === 'single' ? 70 : 66)); // measured: room for the title above the book")
# move the arrows between stage (spread) and the bottom bar (single)
rep('''  function build(newMode) {''','''  function placeNav() {
    const box = mode === 'spread' ? stage : document.querySelector('.controls');
    box.prepend(prevBtn); box.append(nextBtn);
  }
  function build(newMode) {''')
rep("    fillLedger();\n","    placeNav();\n    fillLedger();\n")
open(S+'/prod/v-7.html','w').write(s)
