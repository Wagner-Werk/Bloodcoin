S='/tmp/claude-0/-home-user-bloodcoin/4d004a14-3986-5f95-8aca-1c599f112a6f/scratchpad'
s=open(S+'/prod/v-6.html').read()
def rep(a,b):
    global s
    assert s.count(a)==1,(a[:70],s.count(a)); s=s.replace(a,b)
# page title above the book, spread counter stays below
rep('<main class="stage" id="stage" aria-label="Bloodcoin, a book in eight leaves">','<main class="stage" id="stage" aria-label="Bloodcoin, a book in eight leaves">\n<div class="pg-title" aria-live="polite"><span id="where">Bloodcoin</span></div>')
rep('<div class="where" aria-live="polite"><span class="c" id="where">Bloodcoin</span><span class="h" id="hint">','<div class="where"><span class="h" id="hint">')
rep('</style>\n</head>','''
.pg-title{position:absolute;left:0;right:0;z-index:4;top:calc(50% - var(--ph) / 2 - 34px);text-align:center;padding:0 16px;font:italic 19px/1.2 var(--f-italic);color:#e6d3a8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
/* desktop: arrows sit left and right of the book */
.single .pg-title{top:calc(50% - var(--ph) / 2 - 66px)}
.stage>.nav{position:absolute;top:50%;transform:translateY(-50%);z-index:5}
.stage>#prev{left:calc(50% - var(--pw) - 60px)}.stage>#next{right:calc(50% - var(--pw) - 60px)}
.side.l{left:max(16px,calc(50% - var(--pw) - 290px))}.side.r{right:max(16px,calc(50% - var(--pw) - 290px))}
</style>
</head>''')
rep("const side = W >= 1100 ? 472 : 0;","const side = W >= 1100 ? 548 : 0;")
rep("H - (m === 'single' ? 214 : W < 1100 ? 184 : 160)","H - (m === 'single' ? 250 : W < 1100 ? 216 : 190)")
# move the arrows between stage (spread) and the bottom bar (single)
rep('''  function build(newMode) {''','''  function placeNav() {
    const box = mode === 'spread' ? stage : document.querySelector('.controls');
    box.prepend(prevBtn); box.append(nextBtn);
  }
  function build(newMode) {''')
rep("    fillLedger();\n","    placeNav();\n    fillLedger();\n")
open(S+'/prod/v-7.html','w').write(s)
