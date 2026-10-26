S='/tmp/claude-0/-home-user-bloodcoin/4d004a14-3986-5f95-8aca-1c599f112a6f/scratchpad'
s=open(S+'/prod/v-7.html').read()
CSS='''
.acct{position:fixed;top:44px;right:16px;z-index:8;font-family:var(--f-body)}
.acct-btn{display:flex;align-items:center;gap:.5em;background:rgba(8,5,4,.88);border:1px solid rgba(201,162,90,.6);color:#eadfc4;padding:7px 14px;border-radius:2px;font:500 11px var(--f-mono);letter-spacing:.14em;text-transform:uppercase;cursor:pointer}
.acct-btn svg{width:12px;height:16px;color:var(--blood-hi)}
.acct-panel{position:absolute;right:0;top:calc(100% + 8px);width:300px;background:radial-gradient(ellipse at 50% 40%,var(--paper) 55%,var(--paper-2) 100%);color:#2a1d12;padding:20px 22px 16px;box-shadow:0 18px 40px rgba(0,0,0,.75),inset 0 0 0 1px rgba(120,90,50,.35),inset 0 0 0 5px rgba(234,223,196,.9),inset 0 0 0 6px rgba(143,16,22,.35)}
.acct-panel .eyebrow{font:500 10px var(--f-mono);letter-spacing:.16em;text-transform:uppercase;color:var(--blood)}
.acct-panel h3{margin:.15em 0 .5em;font:400 22px var(--f-display);letter-spacing:.02em}
.acct-panel label{display:block;font:500 9.5px var(--f-mono);letter-spacing:.14em;text-transform:uppercase;color:#6b5236;margin:.7em 0 .25em}
.acct-panel input{width:100%;box-sizing:border-box;border:0;border-bottom:1px solid #8a6a44;background:rgba(255,250,235,.55);padding:7px 8px;font:15px var(--f-body);color:#2a1d12}
.acct-panel .go{margin-top:14px;width:100%;background:var(--blood);color:#f6e8c4;border:0;padding:9px;font:600 12px var(--f-body);letter-spacing:.14em;text-transform:uppercase}
.acct-panel .or{display:flex;align-items:center;gap:.6em;margin:12px 0 10px;font:italic 13px var(--f-italic);color:#7a5e3e}
.acct-panel .or::before,.acct-panel .or::after{content:"";flex:1;border-top:1px solid rgba(120,90,50,.4)}
.acct-panel .wallet{width:100%;background:transparent;border:1px solid var(--blood);color:var(--blood);padding:8px;font:600 12px var(--f-body);letter-spacing:.12em;text-transform:uppercase}
.acct-panel .fine{margin:12px 0 0;font:italic 12px/1.35 var(--f-italic);color:#6b5236;text-align:center}
.acct-panel .links{display:flex;justify-content:space-between;margin-top:8px;font-size:12.5px}.acct-panel .links a{color:var(--blood)}
@media (max-width:600px){.acct{top:auto;bottom:auto;top:64px;right:10px}.acct-btn{padding:5px 10px;font-size:10px}.acct-panel{position:fixed;left:10px;right:10px;width:auto;top:96px}}
'''
DROP='<svg viewBox="0 0 10 14"><path d="M5 0C5 0 0 6.5 0 9a5 5 0 0 0 10 0C10 6.5 5 0 5 0z" fill="currentColor"/></svg>'
PANEL=f'''<div class="acct"><button class="acct-btn">{DROP}Sign in</button>
<div class="acct-panel" OPEN><div class="eyebrow">The Register · Account</div><h3>Sign in</h3>
<label>Email</label><input value="" placeholder="you@example.com">
<label>Password</label><input type="password" value="••••••••••">
<label>Authenticator code</label><input placeholder="6 digits">
<button class="go">Sign in</button>
<div class="links"><a>Create account</a><a>Forgot password?</a></div>
<div class="or">or</div>
<button class="wallet">Connect wallet</button>
<p class="fine">Demo exchange with test money only. BCUS is not yet available for purchase.</p>
</div></div>'''
s=s.replace('</style>\n</head>',CSS+'</style>\n</head>',1)
for mode in ['open','closed']:
    html=s.replace('</body>',PANEL.replace(' OPEN','' if mode=='open' else ' hidden')+'\n</body>',1)
    open(f'{S}/prod/v-login-{mode}.html','w').write(html)
