import json, os, glob
SP = os.path.join(os.environ.get("TEMP", "."), "yawmi-demo")  # scratch files (pages, raw screenshots)
TOOLS = os.path.dirname(os.path.abspath(__file__))
p = os.path.join(os.path.dirname(TOOLS), "guide.html")
s = open(p, encoding="utf-8").read()

# topics generated so far (demo.py writes tools/<topic>.json): name shown on the chip
NAMES = {"shop": "🛒 المشتريات"}
ORDER = ["shop"]
demos = []
for t in ORDER:
    raw = open(os.path.join(TOOLS, t + ".json"), encoding="utf-8").read()
    steps = json.JSONDecoder().raw_decode(raw)[0]
    demos.append({"id": t, "name": NAMES[t], "steps": [{"img": x["img"], "x": x["x"], "y": x["y"], "cap": x["cap"]} for x in steps]})
data = json.dumps(demos, ensure_ascii=False, separators=(",", ":"))

CSS = """/* Animated how-tos: real screenshots in a phone frame, a finger that moves to the button and taps it */
.demos { margin-top: 22px; background: var(--surface); border: 1px solid var(--line); border-radius: 18px; padding: 16px 18px; }
.demos h2 { margin: 0 0 4px; font-family: var(--font-display); font-size: 1.2rem; }
.demos > p { margin: 0 0 10px; color: var(--muted); font-size: .92rem; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 14px; }
.chips button { border: 1px solid var(--line); background: var(--bg); color: var(--ink); border-radius: 99px; padding: 6px 14px; font: inherit; font-size: .9rem; font-weight: 600; cursor: pointer; }
.chips button[aria-pressed="true"] { background: var(--accent-soft); border-color: var(--accent); color: var(--accent); }
.player { display: grid; grid-template-columns: minmax(0, 300px) minmax(0, 1fr); gap: 18px; align-items: center; }
@media (max-width: 620px) { .player { grid-template-columns: 1fr; justify-items: center; } }
.phone { position: relative; width: min(300px, 78vw); aspect-ratio: 1 / 2; border: 8px solid #1A2230; border-radius: 30px; overflow: hidden; background: #F4F6F8; box-shadow: 0 10px 30px rgba(0, 0, 0, .18); }
.phone img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; transition: opacity .35s; }
.finger { position: absolute; z-index: 2; font-size: 2.1rem; line-height: 1; transform: translate(-38%, -8%); transition: left .9s ease-in-out, top .9s ease-in-out; filter: drop-shadow(0 2px 3px rgba(0, 0, 0, .35)); pointer-events: none; }
.finger.tap { animation: tap .5s ease-in-out; }
@keyframes tap { 50% { transform: translate(-38%, -8%) scale(.82); } }
.ring { position: absolute; z-index: 1; width: 44px; height: 44px; margin: -22px 0 0 -22px; border-radius: 50%; border: 3px solid var(--star); opacity: 0; pointer-events: none; }
.ring.go { animation: ring .7s ease-out; }
@keyframes ring { 0% { opacity: .9; transform: scale(.4); } 100% { opacity: 0; transform: scale(1.4); } }
.dside { display: flex; flex-direction: column; gap: 10px; width: 100%; }
.dstep { margin: 0; color: var(--accent); font-weight: 700; font-size: .9rem; }
.dcap { margin: 0; font-size: 1.15rem; font-weight: 600; line-height: 1.7; min-height: 3.4em; }
.dctl { display: flex; gap: 8px; flex-wrap: wrap; }
.dctl button { border: 1px solid var(--line); background: var(--bg); color: var(--ink); border-radius: 10px; padding: 8px 14px; font: inherit; font-size: .9rem; cursor: pointer; min-height: 40px; }
.dots { display: flex; gap: 6px; }
.dots i { width: 9px; height: 9px; border-radius: 50%; background: var(--line); }
.dots i.on { background: var(--accent); }
@media (prefers-reduced-motion: reduce) { .finger { transition: none; } .finger.tap, .ring.go { animation: none; } }
"""
HTML = """
<section class="demos" id="demos" aria-label="شروحات متحركة">
  <h2>🎬 شاهد كيف</h2>
  <p>اختر موضوعًا، فيعرض لك الخطوات على شاشة التطبيق نفسها.</p>
  <div class="chips" id="dTabs"></div>
  <div class="player">
    <div class="phone"><img id="dImg" alt=""><span class="ring" id="dRing"></span><span class="finger" id="dFinger" aria-hidden="true">👆</span></div>
    <div class="dside">
      <p class="dstep" id="dStep"></p>
      <p class="dcap" id="dCap" aria-live="polite"></p>
      <div class="dctl"><button id="dPrev">→ السابق</button><button id="dPlay">⏸ إيقاف</button><button id="dNext">التالي ←</button></div>
      <div class="dots" id="dDots"></div>
    </div>
  </div>
</section>
"""
JS = """<script>
(function () {
  var DEMOS = %s;
  var $ = function (id) { return document.getElementById(id); };
  var cur = DEMOS[0], i = 0, timer = null, playing = true, AR = "٠١٢٣٤٥٦٧٨٩";
  var ar = function (n) { return String(n).replace(/[0-9]/g, function (d) { return AR[d]; }); };
  function show() {
    var st = cur.steps[i], img = $("dImg"), f = $("dFinger"), r = $("dRing");
    img.style.opacity = 0;
    setTimeout(function () { img.src = st.img; img.alt = st.cap; img.style.opacity = 1; }, 180);
    f.style.left = (st.x * 100) + "%%"; f.style.top = (st.y * 100) + "%%";
    r.style.left = (st.x * 100) + "%%"; r.style.top = (st.y * 100) + "%%";
    f.classList.remove("tap"); r.classList.remove("go");
    setTimeout(function () { f.classList.add("tap"); r.classList.add("go"); }, 1000);
    $("dStep").textContent = cur.name + " · الخطوة " + ar(i + 1) + " من " + ar(cur.steps.length);
    $("dCap").textContent = st.cap;
    $("dDots").innerHTML = cur.steps.map(function (_, k) { return '<i class="' + (k === i ? "on" : "") + '"></i>'; }).join("");
    if (cur.steps[i + 1]) new Image().src = cur.steps[i + 1].img;
    clearTimeout(timer);
    if (playing) timer = setTimeout(function () { i = (i + 1) %% cur.steps.length; show(); }, 4200);
  }
  function pick(id) {
    cur = DEMOS.filter(function (d) { return d.id === id; })[0] || DEMOS[0]; i = 0;
    $("dTabs").innerHTML = DEMOS.map(function (d) { return '<button data-id="' + d.id + '" aria-pressed="' + (d === cur) + '">' + d.name + '</button>'; }).join("");
    show();
  }
  $("dTabs").addEventListener("click", function (e) { var b = e.target.closest("button"); if (b) { playing = true; $("dPlay").textContent = "⏸ إيقاف"; pick(b.dataset.id); } });
  $("dPrev").addEventListener("click", function () { i = (i - 1 + cur.steps.length) %% cur.steps.length; show(); });
  $("dNext").addEventListener("click", function () { i = (i + 1) %% cur.steps.length; show(); });
  $("dPlay").addEventListener("click", function () { playing = !playing; this.textContent = playing ? "⏸ إيقاف" : "▶ تشغيل"; show(); });
  var want = location.hash.slice(1);
  pick(want);
  if (want && DEMOS.some(function (d) { return d.id === want; })) $("demos").scrollIntoView();
})();
</script>
""" % data

if "/* Animated how-tos" in s:
    a = s.index("/* Animated how-tos"); b = s.index("</style>")
    s = s[:a] + CSS + s[b:]
    a = s.index('\n<section class="demos"'); b = s.index("</section>", a) + len("</section>\n")
    s = s[:a] + HTML + s[b:]
    a = s.index("<script>\n(function () {\n  var DEMOS"); b = s.index("</script>\n", a) + len("</script>\n")
    s = s[:a] + JS + s[b:]
else:
    s = s.replace("</style>", CSS + "</style>", 1)
    s = s.replace('\n<div class="cards">', HTML + '\n<div class="cards">', 1)
    s = s.replace("</body>", JS + "</body>", 1)
open(p, "w", encoding="utf-8", newline="").write(s)
print("ok", len(data))
