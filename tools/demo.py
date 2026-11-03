"""Builds an animated how-to for guide.html from the real app: screenshots of each step plus where the pointer goes.
usage: python demo.py <topic>   (topics in TOPICS below) -> D:\\Time Management\\guide\\<topic>-<n>.webp + printed JSON"""
import json, os, subprocess, sys, re, shutil
from PIL import Image

SP = os.path.join(os.environ.get("TEMP", "."), "yawmi-demo")  # scratch files (pages, raw screenshots)
TOOLS = os.path.dirname(os.path.abspath(__file__))
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(APP, "guide")
W, H, SCALE = 500, 1000, 2

# a lived-in account: a name, today's plan, prayer times and Quran on
SETUP = r'''
var t=new Date(),k=t.getFullYear()+"-"+("0"+(t.getMonth()+1)).slice(-2)+"-"+("0"+t.getDate()).slice(-2);
function it(id,title,cat,time,dur,top,done){return {id:id,title:title,cat:cat,time:time,dur:dur,important:true,urgent:!!top,top:!!top,done:!!done,spent:done?dur:null,note:"",u:1}}
var st={v:3,days:{},settings:{categories:[{id:"study",name:"الدراسة",color:1},{id:"worship",name:"العبادات",color:2},{id:"work",name:"العمل",color:3},{id:"health",name:"الصحة والرياضة",color:4},{id:"family",name:"الأسرة",color:5},{id:"other",name:"أخرى",color:6}],routines:[],updatedAt:1},shop:{items:[],del:{}},dirtyDays:{}};
st.days[k]={items:[it("a1","مراجعة الفصل الثالث","study","08:00",120,1,1),it("a2","زيارة الوالدين","family","17:00",60,1),it("a3","رياضة / مشي","health","19:00",45)],good:"",improve:"",notes:"",startAt:"08:00",applied:[],updatedAt:1};
localStorage.setItem("daily-planner-v3",JSON.stringify(st));localStorage.setItem("yawmi-username","محمد");localStorage.setItem("yawmi-since",String(Date.now()));localStorage.setItem("yawmi-share-asked","1");
'''

H_ = r'''function q(x){return document.querySelector(x)}function qa(x){return [].slice.call(document.querySelectorAll(x))}
function type(sel,v){var e=q(sel);e.value=v;e.dispatchEvent(new Event("input",{bubbles:true}));}
function submit(sel){q(sel).dispatchEvent(new Event("submit",{bubbles:true,cancelable:true}));}
function chk(e){e.checked=!e.checked;e.dispatchEvent(new Event("change",{bubbles:true}));}'''

TOPICS = {
    "shop": [
        ('q(\'.tab[data-tab="day"]\').click();', '.tab[data-tab="shop"]', "اضغط «المشتريات» أسفل الشاشة"),
        ('q(\'.tab[data-tab="shop"]\').click();type("#shopInput","حليب ٢");q("#shopSec").value="dairy";', 'form[data-form="shop"] button[type=submit]', "اكتب الغرض، واختر قسمه، ثم اضغط «أضف»"),
        ('submit(\'form[data-form="shop"]\');[["طماطم","veg"],["خبز","dairy"],["رز","food"],["صابون","clean"],["دجاج","meat"]].forEach(function(x){type("#shopInput",x[0]);q("#shopSec").value=x[1];submit(\'form[data-form="shop"]\');});window.scrollTo(0,0);',
         '[data-act="shopDone"]', "الأغراض مرتّبة حسب الأقسام. عند الشراء اضغط على المربع"),
        ('chk(q(\'[data-act="shopDone"]\'));chk(qa(\'[data-act="shopDone"]\').filter(function(e){return !e.checked})[0]);var g=q("#shopGot");g.open=true;g.dispatchEvent(new Event("toggle"));',
         '#shopGot [data-act="shopDone"]', "ما اشتريته ينتقل إلى «اشتريته». وإذا احتجته مرة أخرى أعده بضغطة"),
        ('window.scrollTo(0,0);', '[data-act="shopShare"]', "«📤 أرسل القائمة» ترسلها مرتّبة عبر واتساب لمن يذهب إلى السوق"),
    ],
}


def page(topic, upto, mode):
    s = open(os.path.join(APP, "index.html"), encoding="utf-8").read()
    s = s.replace('<script src="config.js"></script>', '').replace('<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"></script>', '')
    s = s.replace('href="manifest.webmanifest"', 'href="#"').replace('href="icon.svg"', 'href="' + APP.replace("\\", "/") + '/icon.svg"', 1)
    s = s.replace('src="icon.svg"', 'src="file:///' + APP.replace("\\", "/") + '/icon.svg"')
    s = s.replace("<head>", "<head><script>" + SETUP + "</script>", 1)
    steps = TOPICS[topic]
    body = H_ + "var R=[];"
    for i, (act, target, _) in enumerate(steps[:upto + 1]):
        body += "try{" + act + "}catch(e){R.push({err:String(e)})}"
        body += "var el=q('%s');if(el){var r0=el.getBoundingClientRect();if(r0.top<0||r0.bottom>innerHeight-70)el.scrollIntoView({block:'center'});var r=el.getBoundingClientRect();R.push({iw:innerWidth,ih:innerHeight});R.pop();R.push({x:r.left+r.width/2,y:r.top+r.height/2,iw:innerWidth,ih:innerHeight});}else R.push({miss:'%s'});" % (target.replace("'", "\\'"), target.replace("'", "\\'"))
    if mode == "coords":
        body += 'var p=document.createElement("pre");p.id="RES";p.textContent=JSON.stringify(R);document.body.appendChild(p);'
    i = s.rindex("</body>")
    s = s[:i] + "<script>setTimeout(function(){" + body + "},1500);</script></body>" + s[i + 7:]
    os.makedirs(SP, exist_ok=True)
    f = os.path.join(SP, "demo_%s_%d_%s.html" % (topic, upto, mode))
    open(f, "w", encoding="utf-8").write(s)
    return f


def edge(args, out):
    prof = os.path.join(SP, "dp_" + os.path.basename(out))
    shutil.rmtree(prof, ignore_errors=True)
    with open(out, "w", encoding="utf-8") as fo:
        subprocess.run([EDGE, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--user-data-dir=" + prof, "--virtual-time-budget=6000"] + args, stdout=fo, stderr=subprocess.DEVNULL, timeout=120)


def run(topic):
    steps = TOPICS[topic]
    n = len(steps) - 1
    f = page(topic, n, "coords")
    o = os.path.join(SP, "coords.txt")
    edge(["--window-size=%d,%d" % (W + 26, H + 93), "--force-device-scale-factor=%d" % SCALE, "--dump-dom", "file:///" + f.replace("\\", "/")], o)
    m = re.search(r'<pre id="RES">(.*?)</pre>', open(o, encoding="utf-8").read(), re.S)
    R = json.loads(m.group(1)) if m else []
    os.makedirs(OUT, exist_ok=True)
    res = []
    for i in range(len(steps)):
        f = page(topic, i, "shot")
        png = os.path.join(SP, "shot_%s_%d.png" % (topic, i))
        edge(["--window-size=%d,%d" % (W, H), "--force-device-scale-factor=%d" % SCALE, "--screenshot=" + png, "file:///" + f.replace("\\", "/")], os.path.join(SP, "o_shot.txt"))
        img = Image.open(png).convert("RGB")
        img = img.resize((W * 6 // 5, H * 6 // 5), Image.LANCZOS)
        name = "%s-%d.webp" % (topic, i + 1)
        img.save(os.path.join(OUT, name), "WEBP", quality=72, method=6)
        c = R[i] if i < len(R) else {}
        res.append({"img": "guide/" + name, "x": round(c.get("x", W / 2) / W, 3), "y": round(c.get("y", H / 2) / H, 3), "cap": steps[i][2]})
    json.dump(res, open(os.path.join(TOOLS, topic + ".json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps(res, ensure_ascii=False, indent=1))
    print("sizes:", [os.path.getsize(os.path.join(OUT, "%s-%d.webp" % (topic, i + 1))) // 1024 for i in range(len(steps))], "KB")


run(sys.argv[1])
