S='/tmp/claude-0/-home-user-bloodcoin/4d004a14-3986-5f95-8aca-1c599f112a6f/scratchpad'
s=open(S+'/prod/index.html').read()
CSS='''
/* side columns (desktop >=1100px) in ledger style; ticker line on smaller screens */
.side{position:fixed;top:56px;bottom:16px;width:210px;z-index:3;display:flex;flex-direction:column;justify-content:center;gap:18px;color:#eadfc4;font-family:var(--f-body);font-size:13px;line-height:1.32}
.side.l{left:max(16px,calc(50% - var(--pw) - 236px))}.side.r{right:max(16px,calc(50% - var(--pw) - 236px))}
.side section{background:rgba(8,5,4,.82);border-top:1px solid rgba(201,162,90,.6);border-bottom:1px solid rgba(201,162,90,.6);padding:10px 14px}
.side .lbl{font:500 10px var(--f-mono);letter-spacing:.16em;text-transform:uppercase;color:var(--gold)}
.side b.big{display:block;font:500 19px var(--f-body);color:#f3e6c6;margin:.2em 0 .1em;font-variant-numeric:lining-nums}
.side i{display:block;opacity:.85}.side a{color:var(--gold)}
.side .ev{padding-top:.55em;margin-top:.55em;border-top:1px dotted rgba(201,162,90,.3)}
.side .ev span{display:block;font:10.5px var(--f-mono);color:var(--gold);opacity:.8}.side .ev b{display:block;font-weight:500}.side .ev i{font-size:12px}
.ticker{display:none;flex:none;overflow:hidden;white-space:nowrap;height:24px;line-height:24px;background:#0b0605;border-bottom:1px solid rgba(201,162,90,.3);font:12px var(--f-mono);color:#e8d9b4;position:relative;z-index:2}
.ticker .run{display:inline-block;padding-left:100%;animation:tick 38s linear infinite}
.ticker em{font-style:normal;color:var(--gold);letter-spacing:.12em;margin-right:.5em}.ticker .sep{color:var(--blood-hi);margin:0 1.1em}
@keyframes tick{to{transform:translateX(-100%)}}
@media (prefers-reduced-motion:reduce){.ticker{overflow-x:auto}.ticker .run{animation:none;padding-left:16px}}
@media (max-width:1099px){.side{display:none}.ticker{display:block}}
'''
SIDES='''<aside class="side l" aria-label="Record">
<section><div class="lbl">Latest report</div><b class="big">222,277 deaths</b><i>in four weeks to 2026-08-22</i><i>Mortality factor 1.000</i><i class="m"><a>0x789d031a…</a> on Base</i></section>
<section><div class="lbl">Project log</div>
<div class="ev" style="border:0;margin:0"><span>Oct 25, 2026</span><b>First weekly emission (test network)</b><i>Scheduled on Base Sepolia. Test tokens have no value.</i></div>
<div class="ev"><span>Oct 21, 2026</span><b>Whitepaper 1.0 draft</b><i>The full mechanism, risks and limits.</i></div>
<div class="ev"><span>Oct 18, 2026</span><b>New test deployment</b><i>Six contracts on Base Sepolia, verified.</i></div></section>
</aside>
<aside class="side r" aria-label="Network">
<section><div class="lbl">Next emission</div><b class="big">in 1 d 2 h</b><i>First emission, Oct 25, 15:18 UTC</i><i>Half to miners, half to stakers.</i></section>
<section><div class="lbl">Mining on Base</div><b class="big">0 solutions</b><i>Starts with the first emission.</i></section>
<section><div class="lbl">Bloodcoin chain</div><b class="big">Block 34,182</b><i>every 26 s · <a>explorer</a> · <a>all reports</a></i></section>
</aside>'''
TICK=('<div class="ticker" aria-label="Live record"><span class="run">'
 '<em>LATEST REPORT</em>222,277 deaths in four weeks to 2026-08-22 · factor 1.000<span class="sep">◆</span>'
 '<em>NEXT EMISSION</em>in 1 d 2 h · Oct 25, 15:18 UTC<span class="sep">◆</span>'
 '<em>MINING</em>0 solutions<span class="sep">◆</span>'
 '<em>CHAIN</em>Block 34,182 · every 26 s<span class="sep">◆</span>'
 '<em>LOG</em>Oct 25 first weekly emission (test network)</span></div>')
s=s.replace('</style>\n</head>',CSS+'</style>\n</head>',1)
a='<div class="banner" role="note"><b>IN DEVELOPMENT</b>Bloodcoin is still in development. BCUS is not yet available for purchase.</div>'
assert a in s; s=s.replace(a,a+'\n'+TICK,1)
s=s.replace('</body>',SIDES+'\n</body>',1)
old="    let pw = m === 'single' ? Math.min(W - 32, 480) : Math.min((W - 64) / 2, 500);"
assert old in s
s=s.replace(old,"    const side = W >= 1100 ? 472 : 0; // room for the two info columns\n    let pw = m === 'single' ? Math.min(W - 32, 480) : Math.min((W - 64 - side) / 2, 500);")
old2="const availH = Math.max(380, H - (m === 'single' ? 190 : 160));"
assert old2 in s
s=s.replace(old2,"const availH = Math.max(380, H - (m === 'single' ? 214 : W < 1100 ? 184 : 160));")
open(S+'/prod/v-6.html','w').write(s)
