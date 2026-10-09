# Аудитор

## Скилл

[Скилл](auditor_skill.md)

## Инструмент

```python
"""Numeric citation audit and safe renumbering. Python 3.10+, standard library only.

PDF support is optional: it needs ``pypdf`` (see the citation-auditor skill).
Nothing here modifies the input document; ``--fix --apply`` writes a new copy.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree as ET

W = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
HEADINGS = {'список литературы', 'список использованной литературы',
            'список использованных источников', 'библиографический список',
            'литература', 'references', 'bibliography'}
ENTRY = re.compile(r'^\s*(?:\[(\d+)\]|(\d+)[.)])\s+(.+)$')
BRACKET = re.compile(r'\[([^\[\]\n]+)\]')
# Page suffix inside a citation: "[3, с. 25–27]", "[3, pp. 25]".
PAGE_SUFFIX = re.compile(r',\s*((?:с\.|стр\.|p\.|pp\.)\s*\d+(?:\s*[-–—]\s*\d+)?)\s*$', re.I)
PDF_HINT = ('Для PDF нужен пакет pypdf: '
            'uv pip install --target "${HERMES_HOME:-$HOME/.hermes}/.pylibs" pypdf')

_pdf_reader = None
_pdf_tried = False


@dataclass
class Paragraph:
    text: str
    location: str
    heading: bool = False
    numbered: bool = False
    source_index: int | None = None


def heading_key(text):
    return re.sub(r'\s+', ' ', text.strip().strip('#* ').rstrip(':').strip()).casefold()


def _pdf_search_paths():
    """Dirs where pypdf may live, in priority order."""
    home = Path(os.environ.get('HERMES_HOME') or (Path.home() / '.hermes'))
    candidates = [os.environ.get('HERMES_LAZY_INSTALL_TARGET'),
                  str(home / '.pylibs'),
                  str(Path.home() / '.pylibs'),
                  '/opt/data/.pylibs']
    seen, out = set(), []
    for cand in candidates:
        if cand and cand not in seen and Path(cand).is_dir():
            seen.add(cand)
            out.append(cand)
    return out


def _pdf_backend():
    """Return pypdf's PdfReader, or None. Adds known install dirs to sys.path."""
    global _pdf_reader, _pdf_tried
    if _pdf_tried:
        return _pdf_reader
    _pdf_tried = True
    try:
        from pypdf import PdfReader
    except ImportError:
        for cand in _pdf_search_paths():
            if cand not in sys.path:
                sys.path.append(cand)
        try:
            from pypdf import PdfReader
        except ImportError:
            return None
    _pdf_reader = PdfReader
    return _pdf_reader


def read_pdf(path, warnings):
    reader_cls = _pdf_backend()
    if reader_cls is None:
        raise ValueError(PDF_HINT)
    reader = reader_cls(str(path))
    paragraphs = []
    empty_pages = 0
    for pno, page in enumerate(reader.pages, 1):
        try:
            text = page.extract_text() or ''
        except Exception:
            text = ''
        if not text.strip():
            empty_pages += 1
        for i, line in enumerate(text.splitlines(), 1):
            paragraphs.append(Paragraph(
                line, f'стр. {pno}, строка {i}',
                heading=heading_key(line) in HEADINGS))
    if empty_pages:
        warnings.append(f'PDF: текст не извлечён с {empty_pages} стр. — '
                        'возможен скан без текстового слоя, нужен OCR.')
    warnings.append('PDF: извлечение текста приблизительное — переносы слов, '
                    'колонки и OCR могут искажать номера ссылок.')
    return paragraphs, warnings


def read_document(path):
    path = Path(path)
    warnings = []
    if path.suffix.lower() == '.pdf':
        return read_pdf(path, warnings)
    if path.suffix.lower() == '.docx':
        with zipfile.ZipFile(path) as z:
            info = z.getinfo('word/document.xml')
            if info.file_size > 30_000_000:
                raise ValueError('Слишком большой document.xml (более 30 МБ).')
            root = ET.fromstring(z.read(info))
            for part in ('footnotes', 'endnotes', 'comments'):
                if f'word/{part}.xml' in z.namelist():
                    warnings.append(f'DOCX содержит {part}: эта часть не проверяется.')
            if any(re.match(r'word/(header|footer)\d+\.xml$', n) for n in z.namelist()):
                warnings.append('Колонтитулы DOCX не проверяются.')
        for tag, label in [('txbxContent', 'надписи'), ('ins', 'вставки исправлений'),
                           ('del', 'удаления исправлений'), ('fldChar', 'поля Word'),
                           ('fldSimple', 'простые поля Word')]:
            if root.find('.//' + W + tag) is not None:
                warnings.append(f'Обнаружены {label}: необходима дополнительная проверка.')
        paragraphs = []
        for i, p in enumerate(root.iter(W + 'p'), 1):
            # Nested paragraphs are visited separately; omit them in the parent.
            def own_text(node):
                for child in node:
                    if child.tag == W + 'p':
                        continue
                    if child.tag == W + 't':
                        yield child.text or ''
                    else:
                        yield from own_text(child)
            texts = list(own_text(p))
            text = ''.join(texts)
            style = p.find('./' + W + 'pPr/' + W + 'pStyle')
            name = style.get(W + 'val', '') if style is not None else ''
            paragraphs.append(Paragraph(text, f'XML-абзац {i}',
                              bool(re.match(r'(Heading|Заголовок)\s*\d+', name, re.I)),
                              p.find('./' + W + 'pPr/' + W + 'numPr') is not None))
        warnings.append('DOCX: номера страниц и автоматическая нумерация Word не вычисляются; '
                        'вложенные надписи и изменения требуют ручной сверки.')
        return paragraphs, warnings
    if path.suffix.lower() not in {'.md', '.txt'}:
        raise ValueError('Поддерживаются DOCX, PDF, MD и TXT в UTF-8.')
    lines = path.read_text(encoding='utf-8-sig').splitlines()
    paragraphs = []
    fence_char, fence_size = None, 0
    for i, line in enumerate(lines, 1):
        if path.suffix.lower() == '.md':
            fence = re.match(r'^\s{0,3}(`{3,}|~{3,})(.*)$', line)
            if fence:
                marker, tail = fence.groups()
                if fence_char is None:
                    fence_char, fence_size = marker[0], len(marker)
                elif marker[0] == fence_char and len(marker) >= fence_size and not tail.strip():
                    fence_char = None
                continue
            if fence_char:
                continue
            line = re.sub(r'(`+).*?\1', '', line)
            line = re.sub(r'!?\[[^\]]*\]\([^\n]*?\)', '', line)
        paragraphs.append(Paragraph(line, f'строка {i}', bool(re.match(r'^#{1,6}\s', line)),
                                    source_index=i - 1))
    if fence_char:
        warnings.append('Незакрытый блок кода: текст после его начала исключён.')
    return paragraphs, warnings


def split_document(paragraphs, custom_heading=None):
    names = {heading_key(custom_heading)} if custom_heading else HEADINGS
    hits = [i for i, p in enumerate(paragraphs) if heading_key(p.text) in names]
    if len(hits) != 1:
        raise ValueError('Нужен один однозначный заголовок списка литературы; '
                         'используйте --heading или --bibliography.')
    start = hits[0]
    stop = next((i for i in range(start + 1, len(paragraphs)) if paragraphs[i].heading),
                len(paragraphs))
    return paragraphs[:start], paragraphs[start + 1:stop], paragraphs[start].location


def parse_citation(content):
    """Return source numbers only, or None for a numeric but unsupported shape."""
    parsed = parse_citation_full(content)
    if parsed is None:
        return None
    numbers = []
    for item in parsed['items']:
        if item[0] == 'single':
            numbers.append(item[1])
        else:
            numbers.extend(range(item[1], item[2] + 1))
    return sorted(set(numbers))


def parse_citation_full(content):
    """Parse a bracket body into items, separators and a page suffix.

    Returns ``{'items': [('single', n) | ('range', a, b, dash)], 'seps': [...],
    'suffix': 'с. 25'}`` or None when the shape is not a plain numeric citation.
    """
    content = content.strip()
    suffix = ''
    m = PAGE_SUFFIX.search(content)
    if m:
        suffix = m.group(1)
        content = content[:m.start()].strip()
    if not re.fullmatch(r'\d+(?:\s*[-–—]\s*\d+)?(?:\s*[,;]\s*\d+(?:\s*[-–—]\s*\d+)?)*',
                        content):
        return None
    # Separators keep their trailing space so rendering preserves the original style.
    parts = re.split(r'([,;]\s*)', content)
    tokens, seps = parts[0::2], parts[1::2]
    items = []
    for token in tokens:
        token = token.strip()
        dash = re.fullmatch(r'(\d+)\s*([-–—])\s*(\d+)', token)
        if dash:
            a, b = int(dash.group(1)), int(dash.group(3))
            if a < 1 or b < a or b > 10000 or b - a > 1000:
                return None
            items.append(('range', a, b, dash.group(2)))
        else:
            if not token.isdigit():
                return None
            n = int(token)
            if n < 1 or n > 10000:
                return None
            items.append(('single', n))
    return {'items': items, 'seps': seps, 'suffix': suffix}


def render_citation(items, seps, suffix):
    """Rebuild a bracket body, preserving original separators where they exist."""
    pieces = []
    for idx, item in enumerate(items):
        sep = seps[idx - 1] if 0 < idx <= len(seps) else ('' if idx == 0 else ', ')
        if item[0] == 'single':
            pieces.append((sep, str(item[1])))
        else:
            pieces.append((sep, f'{item[1]}{item[3]}{item[2]}'))
    body = ''.join(sep + text for sep, text in pieces)
    return f'{body}, {suffix}' if suffix else body


def audit(body, bibliography, warnings=None):
    warnings = list(warnings or [])
    entries, unresolved = [], []
    current = None
    for p in bibliography:
        if not p.text.strip():
            continue
        m = ENTRY.match(p.text)
        if m:
            number = int(m[1] or m[2])
            current = {'number': number, 'text': m[3].strip(), 'location': p.location}
            entries.append(current)
            if number < 1:
                unresolved.append({'location': p.location, 'text': p.text,
                                   'kind': 'low_number', 'reason': 'Номер меньше 1'})
        elif current and not p.numbered and not p.heading:
            current['text'] += '\n' + p.text.strip()
            # Continuation can conceal an unnumbered bibliography entry.
            unresolved.append({'location': p.location, 'text': p.text,
                               'kind': 'continuation',
                               'reason': 'Продолжение записи или источник без явного номера'})
        else:
            unresolved.append({'location': p.location, 'text': p.text,
                               'kind': 'unnumbered', 'reason': 'Нет явного номера записи'})
    if not entries:
        warnings.append('Не распознано ни одной записи с явным номером.')
    if unresolved:
        warnings.append('Список разобран не полностью: проверьте строки без явных номеров.')
    citations, unsupported = [], []
    for p in body:
        for match in re.finditer(r'\[([^\[\]\n]+)\]', p.text):
            content = match[1]
            if not re.match(r'\s*\d', content):
                continue
            numbers = parse_citation(content)
            record = {'raw': match[0], 'location': p.location,
                      'context': p.text[max(0, match.start()-90):match.end()+90]}
            if numbers is None:
                unsupported.append(record)
            else:
                record['numbers'] = numbers
                citations.append(record)
    known = {e['number'] for e in entries}
    mentioned = {n for c in citations for n in c['numbers']}
    counts = Counter(e['number'] for e in entries)
    descriptions = defaultdict(list)
    for entry in entries:
        descriptions[re.sub(r'\s+', ' ', entry['text']).strip().casefold()].append(entry['number'])
    gaps = []
    if known and max(known) <= 10000:
        gaps = sorted(set(range(1, max(known)+1)) - known)
    elif known:
        warnings.append('Номера превышают 10000: проверка пропусков не выполнялась.')
    missing = [{**c, 'missing_numbers': sorted(set(c['numbers']) - known)}
               for c in citations if set(c['numbers']) - known]
    return {'scope': 'Основной текст до библиографии; только числовые кандидаты в квадратных скобках.',
            'warnings': warnings, 'bibliography_complete': bool(entries) and not unresolved,
            'entries': entries, 'unresolved_entries': unresolved, 'citations': citations,
            'unsupported_candidates': unsupported, 'unmatched_candidates': missing,
            'duplicate_numbers': sorted(n for n, count in counts.items() if count > 1),
            'possible_duplicate_entries': [ns for ns in descriptions.values() if len(ns) > 1],
            'numbering_gaps': gaps,
            'out_of_order': [e['number'] for e in entries] != sorted(e['number'] for e in entries),
            'not_mentioned_numbers': sorted(known - mentioned),
            'unique_mentioned_numbers': sorted(mentioned)}


# --------------------------------------------------------------------------
# Renumbering plan and safe rewriting
# --------------------------------------------------------------------------

def build_renumber_plan(report, order='compact'):
    """Return ``(plan, blockers)``. Blockers non-empty means: do not touch the text."""
    blockers = []
    entries = report['entries']
    if not entries:
        blockers.append('Не распознано ни одной записи списка — перенумерация невозможна.')
    if report['duplicate_numbers']:
        blockers.append('Повторные номера в списке: '
                        + ', '.join(map(str, report['duplicate_numbers']))
                        + ' — сначала разрешите конфликт вручную.')
    if report['unmatched_candidates']:
        nums = sorted({n for c in report['unmatched_candidates']
                       for n in c['missing_numbers']})
        blockers.append('Ссылки на номера без записей: ' + ', '.join(map(str, nums))
                        + ' — исправьте список или текст до перенумерации.')
    stray = [u for u in report['unresolved_entries'] if u.get('kind') == 'unnumbered']
    if stray:
        blockers.append('Строки списка без явного номера и без предшествующей записи: '
                        + ', '.join(u['location'] for u in stray[:5])
                        + ' — разбор списка неполон.')
    if blockers:
        return None, blockers
    if order == 'citation':
        first_seen = {}
        for idx, citation in enumerate(report['citations']):
            for number in citation['numbers']:
                first_seen.setdefault(number, idx)
        if any(number not in first_seen for number in {e['number'] for e in entries}):
            # Uncited entries keep their relative order at the end.
            pass
        ordered = sorted(entries, key=lambda e: (first_seen.get(e['number'], len(report['citations'])),
                                                 [x['number'] for x in entries].index(e['number'])))
    else:
        ordered = list(entries)
    mapping = {e['number']: i + 1 for i, e in enumerate(ordered)}
    return {'order': order, 'mapping': mapping,
            'ordered_numbers': [e['number'] for e in ordered],
            'entries': {e['number']: e['text'] for e in entries},
            'changes': mapping != {e['number']: e['number'] for e in entries}}, []


def rewrite_citations_in_line(line, mapping):
    """Rewrite confirmed numeric citations only. Returns ``(line, changes)``."""
    out, last, changes = [], 0, []
    for match in BRACKET.finditer(line):
        content = match.group(1)
        if not re.match(r'\s*\d', content):
            continue
        parsed = parse_citation_full(content)
        if parsed is None:
            continue
        pieces, ok = [], True
        for idx, item in enumerate(parsed['items']):
            sep = parsed['seps'][idx - 1] if 0 < idx <= len(parsed['seps']) else (
                '' if idx == 0 else ', ')
            if item[0] == 'single':
                if item[1] not in mapping:
                    ok = False
                    break
                pieces.append((sep, str(mapping[item[1]])))
            else:
                mapped = [mapping.get(n) for n in range(item[1], item[2] + 1)]
                if any(n is None for n in mapped):
                    ok = False
                    break
                if mapped == list(range(mapped[0], mapped[0] + len(mapped))):
                    pieces.append((sep, f'{mapped[0]}{item[3]}{mapped[-1]}'))
                else:
                    # A range that no longer maps to a contiguous run becomes a list.
                    for j, number in enumerate(mapped):
                        pieces.append((sep if j == 0 else ', ', str(number)))
        if not ok:
            continue
        new_content = ''.join(sep + text for sep, text in pieces)
        if parsed['suffix']:
            new_content += ', ' + parsed['suffix']
        if new_content == content:
            continue
        out.append(line[last:match.start()])
        out.append('[' + new_content + ']')
        last = match.end()
        changes.append({'location': None, 'before': match.group(0),
                        'after': '[' + new_content + ']'})
    if not out:
        return line, []
    out.append(line[last:])
    return ''.join(out), changes


def renumber_entry_line(text, new_number):
    """Replace only the leading number of a bibliography entry, keeping the rest."""
    m = ENTRY.match(text)
    if not m:
        return text
    span = m.span(1) if m[1] is not None else m.span(2)
    return text[:span[0]] + str(new_number) + text[span[1]:]


def split_bib_groups(paragraphs):
    """Group bibliography paragraphs into (old_number, [raw paragraph, ...]).

    Blank lines are ignored: they are layout, not entries, and would otherwise
    look like an unnumbered entry.
    """
    groups = []
    for p in paragraphs:
        if not p.text.strip():
            continue
        m = ENTRY.match(p.text)
        if m:
            groups.append([int(m[1] or m[2]), [p]])
        elif groups:
            groups[-1][1].append(p)
        else:
            groups.append([None, [p]])
    return groups


def normalize_citations(text):
    """Blank out citation numbers so a fixed copy can be diffed against the original."""
    def blank(match):
        return '[#]' if re.match(r'\s*\d', match.group(1)) else match.group(0)
    return BRACKET.sub(blank, text)


def normalize_entry_line(line):
    """Blank the leading number of a bibliography entry."""
    m = ENTRY.match(line)
    if not m:
        return line
    span = m.span(1) if m[1] is not None else m.span(2)
    return line[:span[0]] + '#' + line[span[1]:]


def normalize_document(text, paragraphs, bibliography, reordered=False):
    """Blank citation numbers in the body and entry numbers in the list.

    What remains must be byte-identical between the original and the fixed copy;
    anything else means the rewrite touched content it should not have. When the
    list was deliberately reordered, compare its lines as a sorted multiset
    instead of position by position.
    """
    bib_indices = {p.source_index for p in bibliography if p.source_index is not None}
    body_lines, bib_lines = [], []
    for idx, line in enumerate(text.splitlines()):
        if idx in bib_indices:
            bib_lines.append(normalize_entry_line(line))
        else:
            body_lines.append(normalize_citations(line))
    if reordered:
        bib_lines = sorted(bib_lines)
    return '\n'.join(body_lines + bib_lines)


def unified_diff(original, fixed, limit=400):
    lines = list(difflib.unified_diff(original.splitlines(), fixed.splitlines(),
                                      'до', 'после', lineterm='', n=1))
    if len(lines) > limit:
        lines = lines[:limit] + [f'... ещё {len(lines) - limit} строк различий']
    return '\n'.join(lines)


def plan_markdown(report):
    plan = report.get('renumber_plan')
    if plan is None:
        lines = ['## Перенумерация', '']
        for b in report.get('renumber_blockers', []):
            lines.append(f'- Невозможно: {b}')
        return lines
    lines = ['## План перенумерации', '',
             f"Порядок: {plan['order']}. Стрелка показывает старый номер → новый номер.", '',
             '| Старый | Новый | Источник |', '|---|---|---|']
    for old, new in sorted(plan['mapping'].items()):
        text = (plan['entries'].get(old) or '').replace('\n', ' ').replace('|', '/')
        lines.append(f"| {old} | {new} | {text[:90]} |")
    lines += ['', '### Замены в ссылках', '']
    changes = report.get('citation_changes') or []
    lines += [f"- {c['location']}: `{c['before']}` → `{c['after']}`" for c in changes] \
        or ['Замен в ссылках нет.']
    if report.get('applied_to'):
        v = report.get('verification') or {}
        lines += ['', '### Применение', '',
                  f"- Записано: `{report['applied_to']}`",
                  f"- Текст вне ссылок не изменён: {'да' if v.get('outside_text_unchanged') else 'НЕТ'}",
                  f"- Повторный аудит: {'чисто' if v.get('ok') else 'есть замечания'}"
                  f" (записей {v.get('entries', '?')})"]
        for problem in v.get('problems', []):
            lines.append(f"- Проблема: {problem}")
    if report.get('diff'):
        lines += ['', '### Различия файла', '', '```diff', report['diff'], '```']
    return lines


def markdown(report):
    def clean(value):
        return str(value).replace('\n', ' ').replace('`', "'")
    def nums(values):
        return ', '.join(map(str, values)) or 'нет'
    lines = ['# Проверка числовых ссылок', '', report['scope'], '',
             '**Автоматический отчёт: кандидаты требуют проверки контекста агентом.**', '',
             f"Записей: {len(report['entries'])}; вхождений-кандидатов: {len(report['citations'])}; "
             f"уникальных упомянутых номеров: {len(report['unique_mentioned_numbers'])}.", '',
             '## Ограничения и предупреждения', '']
    lines += ['- ' + w for w in report['warnings']] or ['- Дополнительных предупреждений парсера нет.']
    lines += ['', '## Кандидаты без сопоставленной записи', '']
    if not report['bibliography_complete']:
        lines += ['Список разобран не полностью: отсутствие записи пока не подтверждено.', '']
    for c in report['unmatched_candidates']:
        lines.append(f"- {c['location']}: `{clean(c['raw'])}`; номера {nums(c['missing_numbers'])}. "
                     f"Контекст: {clean(c['context'])}")
    if not report['unmatched_candidates']:
        lines.append('Не обнаружены в распознанных кандидатах.')
    lines += ['', '## Нумерация и возможные дубликаты', '',
              f"- Повторные номера: {nums(report['duplicate_numbers'])}.",
              f"- Пропуски от 1 до максимального номера: {nums(report['numbering_gaps'])}.",
              f"- Нарушен возрастающий порядок: {'да' if report['out_of_order'] else 'нет'}.",
              f"- Совпадающие описания (группы номеров): {report['possible_duplicate_entries'] or 'нет'}.",
              '', '## Нет обнаруженных упоминаний', '', nums(report['not_mentioned_numbers']), '',
              'Это не основание автоматически удалять источники: проверьте полноту текста и требования.',
              '', '## Неоднозначные или неподдержанные конструкции', '']
    lines += [f"- {c['location']}: `{clean(c['raw'])}`. Контекст: {clean(c['context'])}"
              for c in report['unsupported_candidates']] or ['Не обнаружены.']
    lines += ['', '## Неразобранные фрагменты списка', '']
    lines += [f"- {e['location']}: {e['reason']}: {clean(e['text'])}"
              for e in report['unresolved_entries']] or ['Нет.']
    if 'renumber_plan' in report or 'renumber_blockers' in report:
        lines += [''] + plan_markdown(report)
    lines += ['', '## Извлечённые записи для сверки', '']
    lines += [f"- № {e['number']} ({e['location']}): {clean(e['text'])}" for e in report['entries']]
    return '\n'.join(lines) + '\n'


# --------------------------------------------------------------------------
# Applying the fix to a copy
# --------------------------------------------------------------------------

def apply_fix(path, report, plan, order):
    """Write a fixed copy next to the original. Returns (new_path, verification)."""
    path = Path(path)
    raw = path.read_bytes().decode('utf-8')
    had_bom = raw.startswith('\ufeff')
    if had_bom:
        raw = raw.lstrip('\ufeff')
    trailing = '\n' if raw.endswith('\n') else ''
    lines = raw.splitlines()

    paragraphs, warnings = read_document(path)
    body, bibliography, _ = split_document(paragraphs)
    mapping = plan['mapping']

    changes = []
    for p in body:
        if p.source_index is None:
            continue
        new_line, line_changes = rewrite_citations_in_line(lines[p.source_index], mapping)
        if line_changes:
            for change in line_changes:
                change['location'] = p.location
            changes.extend(line_changes)
            lines[p.source_index] = new_line

    if order == 'citation':
        groups = split_bib_groups(bibliography)
        if any(len(group[1]) != 1 or group[0] is None for group in groups):
            raise ValueError('Переупорядочивание невозможно: список содержит продолжения '
                             'записей или строки без номеров.')
        by_number = {group[0]: group[1][0] for group in groups}
        # Replace exactly the span of entry paragraphs; surrounding blanks stay put.
        indices = sorted(by_number[old].source_index for old in plan['ordered_numbers'])
        lines[indices[0]:indices[-1] + 1] = [
            renumber_entry_line(by_number[old].text, mapping[old])
            for old in plan['ordered_numbers']]
    else:
        for p in bibliography:
            if p.source_index is None:
                continue
            line = lines[p.source_index]
            m = ENTRY.match(line)
            if not m:
                continue
            old = int(m[1] or m[2])
            if old in mapping:
                lines[p.source_index] = renumber_entry_line(line, mapping[old])

    fixed = '\n'.join(lines) + trailing
    if had_bom:
        fixed = '\ufeff' + fixed
    out = path.with_name(path.stem + '_renumbered' + path.suffix)
    if out.exists():
        raise ValueError(f'Отказ от перезаписи существующего файла: {out}')
    out.write_text(fixed, encoding='utf-8')

    verification = verify_fix(path, out, body, bibliography, order == 'citation')
    return out, changes, verification


def verify_fix(original_path, fixed_path, body, bibliography, reordered=False):
    """Re-audit the copy and prove nothing outside numbering changed."""
    original = Path(original_path).read_text(encoding='utf-8-sig')
    fixed = Path(fixed_path).read_text(encoding='utf-8-sig')
    result = {'outside_text_unchanged':
              normalize_document(original, body, bibliography, reordered)
              == normalize_document(fixed, body, bibliography, reordered),
              'problems': []}
    if not result['outside_text_unchanged']:
        result['problems'].append('Текст вне номеров ссылок и записей изменился — '
                                  'правку применять нельзя.')
    try:
        paragraphs, warnings = read_document(fixed_path)
        fixed_body, fixed_bib, _ = split_document(paragraphs)
        report = audit(fixed_body, fixed_bib, warnings)
    except Exception as exc:
        result['problems'].append(f'Повторный аудит не выполнен: {exc}')
        return result
    if report['unmatched_candidates']:
        result['problems'].append('Остались ссылки на номера без записей.')
    if report['duplicate_numbers']:
        result['problems'].append('Остались повторные номера в списке.')
    if report['numbering_gaps']:
        result['problems'].append('Остались пропуски нумерации: '
                                  + ', '.join(map(str, report['numbering_gaps'])))
    result['out_of_order'] = report['out_of_order']
    result['gaps'] = report['numbering_gaps']
    result['entries'] = len(report['entries'])
    result['ok'] = not result['problems']
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--bibliography', type=Path)
    parser.add_argument('--heading')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--json', type=Path, dest='json_path')
    parser.add_argument('--fix', action='store_true',
                        help='Построить план перенумерации (без записи файла).')
    parser.add_argument('--apply', action='store_true',
                        help='С --fix записать исправленную копию рядом с исходником.')
    parser.add_argument('--order', choices=['compact', 'citation'], default='compact',
                        help='compact — сохранить порядок записей, закрыть пропуски; '
                             'citation — упорядочить по первому упоминанию в тексте.')
    args = parser.parse_args()
    try:
        if args.apply and not args.fix:
            raise ValueError('--apply работает только вместе с --fix.')
        outputs = [p for p in (args.output, args.json_path) if p]
        if len({p.resolve() for p in outputs}) != len(outputs):
            raise ValueError('Для Markdown и JSON нужны разные выходные файлы.')
        for path in outputs:
            if path.exists():
                raise ValueError(f'Отказ от перезаписи существующего файла: {path}')
        paragraphs, warnings = read_document(args.input)
        if args.bibliography:
            if args.fix:
                raise ValueError('--fix не поддерживает отдельный файл списка: '
                                 'объедините текст и список в один файл.')
            body = paragraphs
            bibliography, more = read_document(args.bibliography)
            names = HEADINGS | ({heading_key(args.heading)} if args.heading else set())
            bibliography = [p for p in bibliography if heading_key(p.text) not in names]
            warnings += more
        else:
            body, bibliography, location = split_document(paragraphs, args.heading)
            warnings.append(f'Библиография начинается после {location}; текст после её следующего '
                            'распознанного заголовка не проверяется.')
        report = audit(body, bibliography, warnings)
        if args.fix:
            plan, blockers = build_renumber_plan(report, args.order)
            report['renumber_blockers'] = blockers
            report['renumber_plan'] = plan
            if plan is not None:
                if args.apply:
                    if Path(args.input).suffix.lower() != '.md' and \
                            Path(args.input).suffix.lower() != '.txt':
                        raise ValueError('Автозапись поддержана только для MD и TXT. '
                                         'Для DOCX/PDF примените план вручную: замена '
                                         'отображаемого текста повредит поля Word.')
                    out, changes, verification = apply_fix(args.input, report, plan, args.order)
                    report['citation_changes'] = changes
                    report['applied_to'] = str(out)
                    report['verification'] = verification
                else:
                    original_lines = Path(args.input).read_text(
                        encoding='utf-8-sig').splitlines()
                    preview_lines, changes = list(original_lines), []
                    for p in body:
                        if p.source_index is None:
                            continue
                        new_line, line_changes = rewrite_citations_in_line(
                            original_lines[p.source_index], plan['mapping'])
                        if line_changes:
                            for change in line_changes:
                                change['location'] = p.location
                            changes.extend(line_changes)
                            preview_lines[p.source_index] = new_line
                    if args.order == 'citation':
                        groups = split_bib_groups(bibliography)
                        if any(len(group[1]) != 1 or group[0] is None for group in groups):
                            raise ValueError('Переупорядочивание невозможно: список содержит '
                                             'продолжения записей или строки без номеров.')
                        by_number = {group[0]: group[1][0] for group in groups}
                        indices = sorted(by_number[old].source_index
                                         for old in plan['ordered_numbers'])
                        preview_lines[indices[0]:indices[-1] + 1] = [
                            renumber_entry_line(by_number[old].text, plan['mapping'][old])
                            for old in plan['ordered_numbers']]
                    else:
                        for p in bibliography:
                            if p.source_index is None:
                                continue
                            m = ENTRY.match(preview_lines[p.source_index])
                            if m and int(m[1] or m[2]) in plan['mapping']:
                                old = int(m[1] or m[2])
                                preview_lines[p.source_index] = renumber_entry_line(
                                    preview_lines[p.source_index], plan['mapping'][old])
                    report['citation_changes'] = changes
                    report['diff'] = unified_diff('\n'.join(original_lines),
                                                  '\n'.join(preview_lines))
        result = markdown(report)
        if args.output:
            with args.output.open('x', encoding='utf-8') as f:
                f.write(result)
        else:
            print(result)
        if args.json_path:
            with args.json_path.open('x', encoding='utf-8') as f:
                json.dump(report, f, ensure_ascii=False, indent=2)
        return 0
    except (OSError, ValueError, KeyError, ET.ParseError, zipfile.BadZipFile) as exc:
        print(f'Ошибка: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
```