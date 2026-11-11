# -*- coding: utf-8 -*-
"""Quick check of «يومي» before publishing: opens index.html in Edge (headless) and clicks through the main screens.

Run from the project folder:   python tools/smoke.py
Each line prints ✓ or ✗. Nothing is sent anywhere: the page runs from a temp copy, without the cloud.
Two modes: "web" (a browser) and "app" (as if opened by the Android app, ?native=…).
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EDGE = [r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe", r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"]

# Runs inside the page. Each check: [name, function returning true/false]. Results go to <html data-test>.
CHECKS = r"""
var R = [], q = function (s) { return document.querySelector(s); }, all = function (s) { return document.querySelectorAll(s).length; };
function ok(name, f) { try { R.push((f() ? "✓ " : "✗ ") + name); } catch (e) { R.push("✗ " + name + " — " + e.message); } }
function tab(t) { var b = q('.tab[data-tab="' + t + '"]'); if (b) b.click(); return !!b; }
function sec() { var b = q('[data-act="alertsOn"]'); return b && b.closest("section"); }
setTimeout(function () {
  ok("الصفحة تعمل بلا أخطاء", function () { return !document.documentElement.getAttribute("data-err"); });
  ok("خطّط", function () { return tab("plan") && all("#view *") > 5; });
  ok("جدولي", function () { return tab("day") && all("#view *") > 5; });
  ok("راجع", function () { return tab("review") && all("#view *") > 5; });
  ok("البحث يفتح", function () { q("#searchBtn").click(); var o = !!q("#srRes"); document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" })); return o; });
  ok("الإعدادات تفتح", function () { q("#setBtn").click(); return all('[data-act="setTab"]') >= 4; });
  ok("الأقسام الظاهرة", function () { return all('[data-act="showF"]') === (APP ? 10 : 9); });
  ok("⏰ " + (APP ? "ظاهر في التطبيق" : "مخفي في المتصفح"), function () { return q("#alarmBtn").hidden === !APP; });
  ok("القرآن: المربع يشغّله", function () {
    var b = q('[data-act="showF"][data-k="quran"]'); if (!b.checked) b.click();
    q('[data-act="setTab"][data-k="wor"]').click(); var o = !!q("#quran");
    q('[data-act="setTab"][data-k="gen"]').click(); q('[data-act="showF"][data-k="quran"]').click();
    q('[data-act="setTab"][data-k="wor"]').click(); var gone = !q("#quran");
    q('[data-act="setTab"][data-k="gen"]').click(); return o && gone;
  });
  ok("التنبيهات: زر واحد يشغّل ويوقف", function () {
    var b = q('[data-act="alertsOn"]'); if (b.getAttribute("aria-pressed") === "true") b.click();
    q('[data-act="alertsOn"]').click(); var on = !!sec().querySelector('[data-act="alertLead"]');
    var right = APP ? !!sec().querySelector('[data-act="natTest"],[data-act="natSettings"]') && !sec().querySelector('[data-act="alertSound"]')
                    : !!sec().querySelector('[data-act="alertSound"]');
    q('[data-act="alertsOn"]').click(); return on && right && !sec().querySelector('[data-act="alertLead"]');
  });
  ok("لا أخطاء بعد الضغطات", function () { return !document.documentElement.getAttribute("data-err"); });
  document.documentElement.setAttribute("data-test", R.join("\n"));
}, 2500);
"""

def run(mode):
    app = mode == "app"
    src = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
    pre = ('localStorage.setItem("yawmi-native","abcdef12");localStorage.setItem("yawmi-native-v","16");' if app
           else 'localStorage.removeItem("yawmi-native");')
    head = '<script>' + pre + 'window.onerror=function(m,u,l){document.documentElement.setAttribute("data-err",m+" @"+l)};</script>'
    body = '<script>var APP=' + ("true" if app else "false") + ';' + CHECKS + '</script>'
    page = src.replace("<head>", "<head>" + head, 1).replace("</body>", body + "</body>", 1)
    tmp = tempfile.mkdtemp(prefix="yawmi-smoke-")
    path = os.path.join(tmp, "t.html")
    open(path, "w", encoding="utf-8").write(page)
    edge = next((e for e in EDGE if os.path.exists(e)), None)
    if not edge: sys.exit("Edge غير موجود")
    dump = os.path.join(tmp, "out.html")
    with open(dump, "w", encoding="utf-8") as f:  # a file, not a pipe: Edge's helper processes keep a pipe open
        try:
            subprocess.run([edge, "--headless=new", "--disable-gpu", "--no-first-run", "--user-data-dir=" + os.path.join(tmp, "p"),
                            "--virtual-time-budget=8000", "--dump-dom", "file:///" + path.replace("\\", "/")],
                           stdout=f, stderr=subprocess.DEVNULL, timeout=90)
        except subprocess.TimeoutExpired:
            return "✗ انتهت المهلة (٩٠ ثانية) ولم يكتمل الفتح"
    out = open(dump, encoding="utf-8", errors="replace").read()
    m = re.search(r'data-test="([^"]*)"', out)
    err = re.search(r'data-err="([^"]*)"', out)
    res = m.group(1).replace("&quot;", '"') if m else "✗ لم تكتمل الفحوص"
    if err: res += "\n✗ خطأ: " + err.group(1)
    return res

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    bad = 0
    for mode in ("web", "app"):
        r = run(mode)
        print("— " + ("المتصفح" if mode == "web" else "تطبيق أندرويد") + " —\n" + r + "\n")
        bad += r.count("✗")
    print("كل الفحوص نجحت ✓" if not bad else str(bad) + " فحص لم ينجح ✗")
    sys.exit(1 if bad else 0)
