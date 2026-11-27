#!/usr/bin/env python3
"""Render the public product registry into the static guide; no browser scripts."""
import html
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
START = "<!-- PRODUCT_STATUS_START -->"
END = "<!-- PRODUCT_STATUS_END -->"
LABELS = {"available": "Доступно", "experimental": "Экспериментально", "development": "В разработке", "planned": "Запланировано"}
def e(value):
    return html.escape(str(value), quote=True)
def link(value):
    if value.startswith("#") and re.fullmatch(r"#[a-z][a-z0-9-]*", value):
        return e(value)
    u = urlsplit(value)
    if u.scheme != "https" or u.netloc != "github.com" or not u.path.startswith("/Misha1302/SecureMesh/"):
        raise ValueError("Unapproved registry URL: " + value)
    return e(value)
def label(item):
    return LABELS[item["status"]]
def render(d):
    if d["productionApproved"] is not False:
        raise ValueError("Production status requires separate review")
    features = "".join(f'<article class="card"><span class="stage-label">{label(f)}</span><h3>{e(f["name"])}</h3><p>{e(f["detail"])}</p></article>' for f in d["features"])
    platforms = []
    for f in d["platforms"]:
        buttons = "".join(f'<a class="btn{"" if i == 0 else " secondary"}" href="{link(l["url"])}">{e(l["label"])}</a>' for i,l in enumerate(f["links"]))
        actions = f'<div class="actions">{buttons}</div>' if buttons else ""
        platforms.append(f'<article class="card"><span class="stage-label">{label(f)}</span><h3>{e(f["name"])}</h3><p><strong>{e(f["label"])}</strong></p><p>{e(f["detail"])}</p>{actions}</article>')
    changes = "".join(f'<article class="card"><span class="stage-label">{e(f["date"])}</span><h3>{e(f["title"])}</h3><p>{e(f["detail"])}</p></article>' for f in d["changes"])
    return f'''<section id="features"><div class="eyebrow">Возможности</div><h2>Что уже умеет SecureMesh</h2><p class="intro">Статус тестовой версии: функции не означают готовность к использованию с чувствительными данными.</p><div class="grid">{features}</div></section>
<section id="downloads"><div class="eyebrow">Приложение / Платформы</div><h2>Скачать SecureMesh</h2><p class="intro">Последняя опубликованная сборка: {e(d["version"])}. <a href="{link(d["releaseUrl"])}">Описание релиза</a> · <a href="{link(d["releaseCI"])}">Проверка сборки</a>.</p><div class="notice"><p><strong>Alpha, не production.</strong> Не используйте реальные чувствительные данные. IPA для iPhone не устанавливается одним нажатием; TestFlight и App Store пока не подтверждены.</p></div><div class="grid product-grid">{"".join(platforms)}</div></section>
<section id="updates"><div class="eyebrow">Журнал обновлений</div><h2>Что нового</h2><div class="grid">{changes}</div><p class="quiet">Реестр обновлён: {e(d["updated"])}. <a href="{link(d["releaseUrl"])}">Последний релиз</a> · <a href="https://github.com/Misha1302/SecureMesh/blob/main/STATUS.md">Технический статус проекта</a>.</p></section>'''
def main():
    d = json.loads((ROOT / "product-status.json").read_text(encoding="utf-8"))
    page = (ROOT / "index.html").read_text(encoding="utf-8")
    if page.count(START) != 1 or page.count(END) != 1:
        raise ValueError("Expected one registry block")
    before, rest = page.split(START, 1)
    _, after = rest.split(END, 1)
    result = before + START + "\n" + render(d) + "\n" + END + after
    ids = re.findall(r'\bid="([^"]+)"', result)
    if len(ids) != len(set(ids)) or set(re.findall(r'href="#([^"]+)"', result)) - set(ids):
        raise ValueError("Duplicate ID or broken internal link")
    if re.search(r'<(?:script|form|iframe)\b', result, re.I):
        raise ValueError("Active content is not allowed")
    Path(sys.argv[1]).write_text(result, encoding="utf-8")
if __name__ == "__main__":
    main()
