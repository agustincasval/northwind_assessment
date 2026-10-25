"""
Turns the two published pages into lightweight HTML that Google Drive converts
into native Google Docs. Charts become <img> tags pointing at the PNGs on GitHub
Pages (Drive fetches them on import). Output: build/gdocs/*.html
Usage: python build/build_gdocs.py [methodology_doc_url]
"""
import re, sys
from pathlib import Path
from bs4 import BeautifulSoup, Comment

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "gdocs"; OUT.mkdir(exist_ok=True)
PAGES = "https://northwind-acv.github.io/plg-conversion-panel"
REPO = "https://github.com/northwind-acv/plg-conversion-panel"
METH_URL = sys.argv[1] if len(sys.argv) > 1 else f"{PAGES}/data-methodology.html"
IMG = {"c0t": "weekly_signups_conversion", "c1t": "signups_by_sku", "c3t": "conversion_by_sku",
       "c4t": "decomposition_waterfall", "c5t": "conversion_by_slice"}
IMG_W = {"c5t": 560}

def clean(path, title):
    soup = BeautifulSoup(Path(path).read_text(), "html.parser")
    for t in soup(["style", "script", "nav", "svg"]):
        t.decompose()
    for t in soup.select("#tip, .sw, .legend"):
        t.decompose()
    for c in soup.find_all(string=lambda x: isinstance(x, Comment)):
        c.extract()
    # figures -> title, subtitle, image
    for fig in soup.find_all("figure"):
        cap = fig.find("figcaption")
        t = cap.select_one(".t"); s = cap.select_one(".s")
        cid = t.get("id")
        new = soup.new_tag("div")
        p = soup.new_tag("p"); b = soup.new_tag("b"); b.string = t.get_text(); p.append(b); new.append(p)
        if cid in IMG:
            img = soup.new_tag("img", src=f"{PAGES}/img/{IMG[cid]}.png", width=str(IMG_W.get(cid, 620)))
            pi = soup.new_tag("p"); pi.append(img); new.append(pi)
        if s:
            ps = soup.new_tag("p"); i = soup.new_tag("i"); i.string = s.get_text().replace("Hover for values.", "").replace(" Hover for Free CRM share and sample size.", "").strip(); ps.append(i); new.append(ps)
        fig.replace_with(new)
    # KPI tiles -> table
    tiles = soup.select_one(".tiles")
    if tiles:
        tbl = soup.new_tag("table", border="1", cellpadding="6")
        tr = soup.new_tag("tr")
        for tile in tiles.select(".tile"):
            td = soup.new_tag("td")
            l = soup.new_tag("p"); l.string = tile.select_one(".l").get_text(); td.append(l)
            v = soup.new_tag("p"); bb = soup.new_tag("b"); bb.string = tile.select_one(".v").get_text(" ", strip=True); v.append(bb); td.append(v)
            d = soup.new_tag("p"); d.string = tile.select_one(".d").get_text(); td.append(d)
            tr.append(td)
        tbl.append(tr); tiles.replace_with(tbl)
    # methodology join map -> one line
    jm = soup.select_one(".joinmap")
    if jm:
        p = soup.new_tag("p"); p.string = "sessions —(session_id, 1 : 0..1)→ signups —(lead_id, 1 : 0..1)→ opportunities"
        jm.replace_with(p)
    # <details> -> heading + pre
    for d in soup.find_all("details"):
        sm = d.find("summary"); pre = d.find("pre")
        h = soup.new_tag("h4"); h.string = sm.get_text()
        d.replace_with(h); h.insert_after(pre)
    # small notes in italics
    for p in soup.select("p.note-foot"):
        p.name = "p"; inner = soup.new_tag("i")
        for c in list(p.contents): inner.append(c.extract())
        p.append(inner)
    for d in soup.select("div.date, div.callout, div.pending"):
        d.name = "p"
    # links
    for a in soup.find_all("a"):
        h = a.get("href", "")
        if h == "data-methodology.html": a["href"] = METH_URL
        elif h == "analysis.html": a["href"] = f"{PAGES}/analysis.html"
        elif h.startswith("#") or h in ("./", ""):
            a.unwrap()
    # tables: border for Docs
    for t in soup.find_all("table"):
        t["border"] = "1"; t["cellpadding"] = "4"; t["cellspacing"] = "0"
    # compact slice tables: drop monthly columns (Jan..Jun), keep Q1/Q2/Δ
    for t in soup.find_all("table"):
        heads = [th.get_text() for th in t.find_all("th")]
        if "Jan" in heads and "Q1" in heads:
            drop = [i for i, h in enumerate(heads) if h in ("Jan", "Feb", "Mar", "Apr", "May", "Jun")]
            for tr in t.find_all("tr"):
                cells = tr.find_all(["td", "th"])
                for i in sorted(drop, reverse=True):
                    if i < len(cells): cells[i].decompose()
    # strip classes / ids / data attrs
    for t in soup.find_all(True):
        for k in list(t.attrs):
            if k in ("class", "id", "role", "aria-labelledby", "style") or k.startswith("data-"):
                del t[k]
    for t in soup.find_all("div"):
        t.unwrap()
    for t in soup.find_all(["sup"]):
        t.unwrap()
    body = soup.find("main") or soup.body
    html = f'<html><head><meta charset="utf-8"><title>{title}</title></head><body style="font-family:Arial">{body.decode_contents()}</body></html>'
    html = re.sub(r"\n\s*\n+", "\n", html)
    return html

for src, name, title in [("docs/data-methodology.html", "data_methodology.html", "Northwind CRM — Data methodology"),
                         ("docs/analysis.html", "analysis.html", "Northwind CRM — Analysis")]:
    h = clean(ROOT / src, title)
    (OUT / name).write_text(h)
    print(name, len(h.encode()), "bytes")
