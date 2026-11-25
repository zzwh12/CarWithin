#!/usr/bin/env python3
"""Regenerate the English receiver from the Chinese player and reviewed translation table."""
import json,re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
rows=json.loads((root/'docs/localization/en/translations.json').read_text())['entries']
s=(root/'App/BrowserReceiverPage.swift').read_text().split('#"""',1)[1].split('"""#',1)[0].strip()
replacements={}
for r in rows:
 if r['scope']!='browser':continue
 zs=re.split(r'\{\d+\}',r['zh']);es=re.split(r'\{\d+\}',r['en'])
 assert len(zs)==len(es)
 for z,e in zip(zs,es):
  if re.search('[\u3400-\u9fff]',z):replacements[z]=e
for z,e in sorted(replacements.items(),key=lambda x:-len(x[0])):s=s.replace(z,e)
s=s.replace('lang="zh-CN"','lang="en"')
if re.search('[\u3400-\u9fff]', s):
 raise SystemExit('Untranslated browser text remains; update translations.json before generating.')
p=root/'App/Localization/Receiver.en.html';p.write_text(s+'\n')
