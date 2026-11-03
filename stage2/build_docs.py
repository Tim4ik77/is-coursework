"""Generate the logical model from an installed database and the DOCX report.
Requires python-docx; database connection uses PG* and PSQL environment variables.
"""
from pathlib import Path
import json
import os
import re
import subprocess
import xml.etree.ElementTree as ET
from html import escape
from docx import Document
from docx.shared import Pt, Cm

ROOT = Path(__file__).resolve().parent
PSQL = os.environ.get('PSQL', 'psql')

def query(sql):
    p = subprocess.run([PSQL, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', sql],
                       check=True, capture_output=True, encoding='utf-8')
    return json.loads(p.stdout)

tables = query("""SELECT json_agg(x ORDER BY x.table_name) FROM (
 SELECT table_name,json_agg(json_build_object('name',column_name,'type',data_type,
 'nullable',is_nullable,'default',column_default,'identity',is_identity) ORDER BY ordinal_position) columns
 FROM information_schema.columns WHERE table_schema='clinic' AND table_name IN
 (SELECT tablename FROM pg_tables WHERE schemaname='clinic') GROUP BY table_name) x""")
constraints = query("""SELECT json_agg(json_build_object('table',c.conrelid::regclass::text,
 'name',c.conname,'type',c.contype,'definition',pg_get_constraintdef(c.oid),
 'target',CASE WHEN c.confrelid<>0 THEN c.confrelid::regclass::text ELSE NULL END))
 FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace WHERE n.nspname='clinic'""")
for c in constraints:
    c['table'] = c['table'].removeprefix('clinic.')
    if c['target']:
        c['target'] = c['target'].removeprefix('clinic.')
model = {'tables': tables, 'constraints': constraints}
(ROOT/'models/schema.json').write_text(json.dumps(model, ensure_ascii=False, indent=2), encoding='utf-8')
lines = ['# Даталогическая модель PostgreSQL', '',
         'Сгенерировано из установленной схемы `clinic`. Точный перечень ограничений приведен под каждой таблицей.', '',
         'Дополнительные межтабличные правила и переходы состояний: `sql/02_integrity.sql`.', '', '```mermaid', 'erDiagram']
for t in tables:
    lines.append('    '+t['table_name']+' {')
    for c in t['columns']:
        typ = c['type'].replace(' ', '_')
        lines.append(f"        {typ} {c['name']}")
    lines.append('    }')
for c in constraints:
    if c['type']=='f':
        lines.append(f"    {c['target']} ||--o{{ {c['table']} : {c['name']}")
lines += ['```', '', 'Диаграмма FK показывает связи родитель–потомки; точная обязательность и уникальность определяются NULL/UNIQUE в словаре ниже. Концептуальные кардинальности — в `er.md`.', '']
for t in tables:
    lines += ['## '+t['table_name'], '', '| Поле | Тип | NULL | По умолчанию |', '|---|---|---|---|']
    for c in t['columns']:
        default = 'IDENTITY' if c['identity']=='YES' else (c['default'] or '—')
        lines.append(f"| {c['name']} | {c['type']} | {c['nullable']} | {default} |")
    lines.append('')
    for c in constraints:
        if c['table']==t['table_name']:
            lines += ['- `'+c['name']+'`: `'+c['definition']+'`']
    lines.append('')
(ROOT/'models/logical.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')

# The diagram is vector-native and editable in diagrams.net.
order = ['users','patients','doctors','specialties','doctor_specialties',
 'doctor_schedules','schedule_breaks','time_slots','daily_quotas','appointments',
 'waitlist_entries','slot_holds','episodes','care_actions','study_results',
 'medical_notes','note_addenda','questionnaires','questions','questionnaire_submissions',
 'questionnaire_answers','notifications','audit_log','system_settings']
lookup={t['table_name']:t for t in tables}
mx=ET.Element('mxfile',host='app.diagrams.net')
dia=ET.SubElement(mx,'diagram',name='PostgreSQL clinic — 24 tables')
graph=ET.SubElement(dia,'mxGraphModel',dx='2500',dy='2200',grid='1',page='0')
root=ET.SubElement(graph,'root')
ET.SubElement(root,'mxCell',id='0'); ET.SubElement(root,'mxCell',id='1',parent='0')
for i,name in enumerate(order):
    t=lookup[name]
    text='<b>'+name+'</b><hr>'+'<br>'.join(escape(c['name']+' : '+c['type']) for c in t['columns'])
    cell=ET.SubElement(root,'mxCell',id=name,value=text,vertex='1',parent='1',
        style='rounded=1;whiteSpace=wrap;html=1;fillColor=#e8f0fc;strokeColor=#55729c;align=left;verticalAlign=top;spacing=10;fontSize=13;')
    ET.SubElement(cell,'mxGeometry',x=str((i%5)*440+40),y=str((i//5)*430+40),width='330',height='330',attrib={'as':'geometry'})
for i,c in enumerate(constraints):
    if c['type']!='f': continue
    cell=ET.SubElement(root,'mxCell',id='fk'+str(i),value='',edge='1',parent='1',source=c['table'],target=c['target'],
        style='edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=ERone;startArrow=ERmany;strokeColor=#758399;')
    ET.SubElement(cell,'mxGeometry',relative='1',attrib={'as':'geometry'})
ET.indent(mx)
ET.ElementTree(mx).write(ROOT/'models/logical.drawio',encoding='utf-8',xml_declaration=True)

doc=Document()
section=doc.sections[0]
section.top_margin=section.bottom_margin=Cm(2)
section.left_margin=Cm(3); section.right_margin=Cm(1.5)
style=doc.styles['Normal']; style.font.name='Times New Roman'; style.font.size=Pt(12)
style.paragraph_format.space_after=Pt(6)

def clean(s):
    s=re.sub(r'\[([^\]]+)\]\(([^)]+)\)',r'\1 (\2)',s)
    return s.replace('**','').replace('`','')

def add_markdown(text):
    rows=text.splitlines(); i=0; in_code=False
    while i<len(rows):
        line=rows[i]
        if line.startswith('```'):
            in_code=not in_code; i+=1; continue
        if in_code:
            i+=1; continue
        if line.startswith('|'):
            group=[]
            while i<len(rows) and rows[i].startswith('|'):
                if not re.match(r'^\|[\s:|\-]+$',rows[i]):
                    group.append([clean(x.strip()) for x in rows[i].strip('|').split('|')])
                i+=1
            if group:
                table=doc.add_table(rows=0,cols=len(group[0])); table.style='Table Grid'
                for row in group:
                    cells=table.add_row().cells
                    for cell,value in zip(cells,row): cell.text=value
            continue
        if line.startswith('#'):
            level=len(line)-len(line.lstrip('#'))
            doc.add_heading(clean(line.lstrip('#').strip()),level=min(level,3))
        elif line.strip():
            doc.add_paragraph(clean(line))
        i+=1

add_markdown((ROOT/'report.md').read_text(encoding='utf-8'))
doc.add_page_break(); doc.add_heading('Приложение А. Словарь данных',level=1)
add_markdown((ROOT/'models/logical.md').read_text(encoding='utf-8'))
doc.save(ROOT/'report.docx')
print(f'Generated logical.md, logical.drawio, schema.json and report.docx: {len(tables)} tables')
