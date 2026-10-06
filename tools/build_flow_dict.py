#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build sound-only (音码) dictionaries for the ``xkjd27c_flow`` schema.

数据源
------
* ``Lambda/ZiDB``（rime_jd27c 仓库）：单字表，提供键道读音与音码；
* 标准拼音词库：``词\\t拼音\\t权重``，构建时把拼音转成键道音码。
  默认 ``pinyin_simp.dict.yaml``（Rime 自带）；
  可用 ``--rime-ice DIR`` 引入 rime-ice 的 ``base`` / ``ext`` / ``others``；
* 纯权重词库：``词\\t权重``（如 rime-ice ``tencent``），
  用单字表读音自动注音（``--rime-ice-tencent`` 启用）。

生成规则
--------
* 单字：全码（声母+韵母，2 键）+ 1 键声母码；
* 词组（键道原版编码）：
  * 2 字：音音全码（如 我们 = ``wu mk``）；
  * 3 字：三个首字母（如 为什么 = ``w u m``）；
  * 4 字：四个首字母（如 万里长城 = ``w l y y``）；
  * 5 字以上：前三首 + 末一首（如 吃一堑长一智 = ``y f q ;``）。

码表里的 code 用**空格分隔音节**（每个字的全码/声母码是一个音节），
这样 prism 的音节表只有几百项，整词由音节序列组成；
不要写成无空格的长串，否则每个词都是独立音节，大数据量时 prism 会爆炸。

不再读取键道 CiDB：形码只做运行时筛选，词库使用标准拼音词库即可。

Use ``--help`` for options.
"""

import argparse
import os
import re
import sys

# ---------------------------------------------------------------------------
# 键道27C 音码映射 (copied from rime_jd27c/Lambda/Layout.py)
# ---------------------------------------------------------------------------

PY_TRANSFORM = {
    'qve': 'que',
    'lve': 'lue',
    'nve': 'nue',
    'jve': 'jue',
    'xve': 'xue',
    'yve': 'yue',
    'm': 'en',
    'ng': 'eng',
}

PY_SHENG = {
    'a': '~', 'ai': '~', 'an': '~', 'ang': '~', 'ao': '~',
    'e': '~', 'ei': '~', 'en': '~', 'eng': '~', 'er': '~',
    'o': '~', 'ou': '~',
}

PY_YUN = {
    'ya': 'ia', 'yan': 'ian', 'yang': 'iang', 'yao': 'iao',
    'ye': 'ie', 'yong': 'iong', 'you': 'iu',
    'ju': 'v', 'qu': 'v', 'xu': 'v', 'yu': 'v',
    'a': 'a', 'ai': 'ai', 'an': 'an', 'ang': 'ang', 'ao': 'ao',
    'e': 'e', 'ei': 'ei', 'en': 'en', 'eng': 'eng', 'er': 'er',
    'o': 'o', 'ou': 'ou',
}

JD_S2K = {
    'q': 'q', 'w': 'w', 'r': 'r', 't': 't', 'y': 'f', 'p': 'p',
    's': 's', 'd': 'd', 'f': 'f', 'g': 'g', 'h': 'h', 'j': 'j',
    'k': 'k', 'l': 'l', 'z': 'z', 'x': 'x', 'c': 'c', 'b': 'b',
    'n': 'n', 'm': 'm', 'zh': ';', 'ch': 'y', 'sh': 'u', '~': 'x',
}

JD_Y2K = {
    'ua': 'q', 'iu': 'q', 'ei': 'w', 'un': 'w', 'e': 'f', 'eng': 'p',
    'uan': 'g', 'ong': 'j', 'iong': 'j', 'ang': 'l', 'a': 'r', 'ia': 'r',
    'ou': 's', 'ie': 's', 'an': 't', 'uai': 'd', 'ing': 'd', 'ai': 'h',
    'ue': 'h', 'u': 'n', 'er': 'n', 'i': 'y', 'uo': 'u', 'v': ';',
    'o': 'u', 'ao': 'z', 'iang': 'x', 'uang': 'x', 'iao': 'c', 'in': 'b',
    'ui': 'b', 'en': 'k', 'ian': 'm',
}

JD_B = {'乛': 'a', '丿': 'e', '丨': 'i', '丶': 'o', '㇐': 'v'}


def transform_py(pinyin):
    pinyin = pinyin.strip().lower()
    return PY_TRANSFORM.get(pinyin, pinyin)


def normalize_py(pinyin):
    """拼音归一化（去声调、统一 ü 拼写），用于按读音对齐权重。"""
    pinyin = re.sub(r'\d+', '', pinyin.strip().lower())
    pinyin = pinyin.replace('ü', 'v').replace('u:', 'v')
    return transform_py(pinyin)


def sheng(py):
    if py in PY_SHENG:
        return PY_SHENG[py]
    if py.startswith('zh'):
        return 'zh'
    if py.startswith('ch'):
        return 'ch'
    if py.startswith('sh'):
        return 'sh'
    return py[0] if py else ''


def yun(py):
    if py in PY_YUN:
        return PY_YUN[py]
    if py.startswith(('zh', 'ch', 'sh')):
        return py[2:]
    return py[1:]


def pinyin2sy(py):
    """全拼 -> 键道音码（双拼两码），无法映射时返回 None。"""
    py = transform_py(py)
    if not py:
        return None
    s, y = sheng(py), yun(py)
    if s not in JD_S2K or y not in JD_Y2K:
        return None
    return JD_S2K[s] + JD_Y2K[y]


def syllable_reading(py):
    """全拼 -> (全码, 声母码)，无法映射时返回 None。"""
    py = transform_py(py)
    if not py:
        return None
    full = pinyin2sy(py)
    if not full:
        return None
    s = sheng(py)
    if s not in JD_S2K:
        return None
    return (full, JD_S2K[s])


def static_sound_code(code_str):
    """把静态码（如 ``<sh><i>k<e><丿><丶>``）中的音码部分提取出来。"""
    tokens = re.findall(r'<[^>]+>|[^<>]', code_str)
    out = []
    for token in tokens:
        if token.startswith('<'):
            name = token[1:-1]
            if name in JD_S2K:
                out.append(JD_S2K[name])
            elif name in JD_Y2K:
                out.append(JD_Y2K[name])
            else:  # 笔画等形码，音码部分结束
                break
        else:
            if token in JD_S2K:
                out.append(JD_S2K[token])
            elif token in JD_Y2K:
                out.append(JD_Y2K[token])
            else:
                break
    return ''.join(out) or None


# ---------------------------------------------------------------------------
# 数据读取
# ---------------------------------------------------------------------------

def parse_weight(text):
    try:
        w = float(text)
    except ValueError:
        return None
    return w if w > 0 else 1.0


def format_weight(weight):
    if weight == int(weight):
        return str(int(weight))
    return ('%.6f' % weight).rstrip('0').rstrip('.')


def iter_dict_rows(path):
    """按行产出 Rime 词典条目（跳过 YAML 头与注释）。"""
    in_header = False
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            if line == '---':
                in_header = True
                continue
            if line == '...':
                in_header = False
                continue
            if in_header:
                continue
            yield line.split('\t')


def load_shape_entries(path):
    """从原版 buchong 里提取纯形码（笔形）条目：code 全部是 aeiov。

    包括原版的「形简」「补充提示」「部首偏旁」三段；「形简」段里每个码
    只保留第一条（形简本体，如 又a）——多出来的（如 识o）原来排在
    shape.dict 的 2 号位，现在交给次简表（flow_secondary.lua）管。
    返回 (entries, extras)，extras 只用于打印。
    """
    entries = []
    extras = []
    seen = set()
    first_of_code = set()
    section = ''
    in_header = False
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line:
                continue
            if line.startswith('#'):
                section = line.lstrip('#').strip()
                continue
            if line == '---':
                in_header = True
                continue
            if line == '...':
                in_header = False
                continue
            if in_header:
                continue
            row = line.split('\t')
            if len(row) < 2 or not row[0] or not row[1]:
                continue
            code = row[1].strip()
            if not code or not re.fullmatch(r'[aeiov]+', code):
                continue
            if section == '形简':
                if code in first_of_code:
                    extras.append((row[0], code))
                    continue
                first_of_code.add(code)
            key = (row[0], code)
            if key in seen:
                continue
            seen.add(key)
            entries.append((row[0], code))
    return entries, extras


def load_original_first(path):
    """原版 danzi 里 code 恰好 1/2 键的精确条目：一简（1 键）/ 全码（2 键）。

    原版每个字只有一个精确全码（形码只用于消歧），所以这些精确条目
    就是原版在 s / sy 上的首选。返回 {码: 首选字}。
    """
    first = {}
    for row in iter_dict_rows(path):
        if len(row) < 2:
            continue
        text, code = row[0].strip(), row[1].strip()
        if text and len(code) in (1, 2):
            first.setdefault(code, text)
    return first


def load_dict(path, default_weight=1.0):
    """读取标准拼音词库。

    返回 ``(char_w, char_reading_w, words, vocab, stats)``：
      * char_w[char] = 字频（取各读音最大）
      * char_reading_w[(char, 拼音)] = 按读音的字频（取各来源最大）
      * words = [(word, [pinyin...], weight)]  （带拼音）
      * vocab = [(word, weight)]               （无拼音，靠单字表自动注音）
    """
    char_w = {}
    char_reading_w = {}
    words = []
    vocab = []
    stats = {'rows': 0, 'chars': 0, 'words': 0, 'vocab': 0, 'skipped': 0}
    for row in iter_dict_rows(path):
        if not row or not row[0]:
            continue
        text = row[0]
        pinyin = None
        weight = None
        if len(row) >= 3:
            if row[1]:
                pinyin = row[1]
            if row[2]:
                weight = parse_weight(row[2])
        elif len(row) == 2:
            if row[1]:
                w = parse_weight(row[1])
                if w is not None:
                    weight = w
                else:
                    pinyin = row[1]
        stats['rows'] += 1
        if len(text) == 1:
            w = weight if weight is not None else default_weight
            if pinyin:
                syllables = pinyin.split()
                if len(syllables) == 1:
                    char_w[text] = max(char_w.get(text, 0.0), w)
                    key = (text, normalize_py(syllables[0]))
                    char_reading_w[key] = max(
                        char_reading_w.get(key, 0.0), w)
            else:
                char_w[text] = max(char_w.get(text, 0.0), w)
            stats['chars'] += 1
            continue
        if pinyin:
            syllables = pinyin.split()
            if len(syllables) != len(text):
                stats['skipped'] += 1
                continue
            words.append(
                (text, syllables, weight if weight is not None else default_weight))
            stats['words'] += 1
        else:
            vocab.append(
                (text, weight if weight is not None else default_weight))
            stats['vocab'] += 1
    return char_w, char_reading_w, words, vocab, stats


def load_zidb(path):
    """读取 ZiDB/通常.txt：单字与读音（含键道短码长度）。"""
    chars = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            row = line.rstrip('\n').split('\t')
            if len(row) < 5:
                continue
            char = row[0]
            pinyins = []
            for i in range(3, len(row) - 1, 2):
                pinyins.append((row[i], int(row[i + 1])))
            chars.append((char, pinyins))
    return chars


def load_zidb_shapes(path):
    """char -> 键道形码（ZiDB 第 3 列的 4 个笔画映射成 aeiov）。"""
    shapes = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            row = line.rstrip('\n').split('\t')
            if len(row) < 5:
                continue
            code = ''.join(JD_B.get(s, '') for s in row[2])
            if code:
                shapes[row[0]] = code
    return shapes


def load_zidb_static(path):
    entries = []
    if not os.path.exists(path):
        return entries
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            row = line.split('\t')
            if len(row) != 2:
                continue
            code = static_sound_code(row[1])
            if code:
                entries.append((row[0], code))
    return entries


# ---------------------------------------------------------------------------
# 音码生成
# ---------------------------------------------------------------------------

def build_char_codes(zidb, zidb_static, char_w, char_reading_w, default_weight):
    """char -> [(全码, 声母码, 权重)]，含 static 音码与多音字。

    权重优先取词库里的按读音字频（见 jian=3460998 / 见 xian=34609）；
    没有则退回「字频 × 键道短码长度衰减」（每长一码低一个数量级），
    再没有字频才用 default_weight 对应的缺省值。
    """
    raw = {}
    for char, pinyins in zidb:
        lens = [w for _, w in pinyins if w > 0]
        base_len = min(lens) if lens else 5
        cw = char_w.get(char)
        for py, jd_w in pinyins:
            if jd_w <= 0:  # 键道标记的无理读音
                continue
            r = syllable_reading(py)
            if not r:
                continue
            full, init = r
            weight = char_reading_w.get((char, normalize_py(py)))
            if weight is None:
                if cw is not None:
                    weight = cw * (10.0 ** (base_len - jd_w))
                else:
                    weight = 10.0 ** (5 - min(jd_w, 5))
            raw.setdefault(char, []).append((full, init, weight))
    for char, code in zidb_static:
        raw.setdefault(char, []).append((code, code[0], default_weight))

    result = {}
    for char, options in raw.items():
        best = {}
        for full, init, weight in options:
            key = (full, init)
            if weight > best.get(key, 0.0):
                best[key] = weight
        result[char] = [(full, init, weight)
                        for (full, init), weight in best.items()]
    return result


def word_code(reading, abbrev_weight, length_weight=1.0):
    """reading = [(全码, 声母码)...] -> (code, 权重系数) 或 None。

    键道原版词组编码：
      n == 2  音音全码（如 我们 = wumk）
      n == 3  3 个首字母（如 为什么 = wum）
      n == 4  4 个首字母（如 万里长城 = wlyy）
      n >= 5  前 3 个首字母 + 末字首字母（如 吃一堑长一智 = yfq;）

    码连写不分音节（table_translator 直接按整串匹配；
    脚本翻译器时代的空格分隔已不需要）。
    length_weight：词组按字数降权，每多 1 字乘一次（n=2 为基准）。
    """
    n = len(reading)
    if n == 2:
        return (''.join(f for f, _ in reading), 1.0)
    scale = abbrev_weight * length_weight ** (n - 2)
    if n in (3, 4):
        initials = [i for _, i in reading]
        if not all(initials):
            return None
        return (''.join(initials), scale)
    if n >= 5:
        head = [i for _, i in reading[:3]]
        tail = reading[-1][1]
        if not all(head) or not tail:
            return None
        return (''.join(head + [tail]), scale)
    return None


def syllables_reading(syllables):
    reading = []
    for py in syllables:
        r = syllable_reading(py)
        if not r:
            return None
        reading.append(r)
    return reading


def auto_reading(word, char_codes):
    """无拼音词：逐字取最高频读音。"""
    reading = []
    for ch in word:
        options = char_codes.get(ch)
        if not options:
            return None
        full, init, _ = max(options, key=lambda o: o[2])
        reading.append((full, init))
    return reading


# ---------------------------------------------------------------------------
# 码表生成
# ---------------------------------------------------------------------------

def build_danzi(char_codes, initial_weight):
    entries = {}
    for char, options in char_codes.items():
        for full, init, weight in options:
            key = (char, full)
            entries[key] = max(entries.get(key, 0.0), weight)
            if init:
                key = (char, init)
                entries[key] = max(entries.get(key, 0.0),
                                   weight * initial_weight)
    return entries


def align_original_first(danzi, first):
    """把原版 1 键/2 键首选字的权重抬到同码第一（其余顺序不动）。

    返回 (调整数, 缺字数)；缺字指原版首选在 ZiDB 读音里对不上。
    """
    per_code = {}
    for (text, code), weight in danzi.items():
        per_code.setdefault(code, []).append((text, weight))
    changed = 0
    missing = 0
    for code, char in first.items():
        entries = per_code.get(code)
        if not entries:
            missing += 1
            continue
        weights = dict(entries)
        if char not in weights:
            missing += 1
            continue
        others = max((w for t, w in entries if t != char), default=0.0)
        if weights[char] <= others:
            danzi[(char, code)] = others + 1.0
            changed += 1
    return changed, missing


def build_cizu(word_entries, vocab_entries, char_codes,
               abbrev_weight, default_weight, length_weight=1.0):
    entries = {}
    skipped = {'pinyin': 0, 'vocab': 0}

    def add(word, code, weight):
        if not code:
            return
        key = (word, code)
        if weight > entries.get(key, 0.0):
            entries[key] = weight

    def add_reading(word, reading, weight):
        r = word_code(reading, abbrev_weight, length_weight)
        if r:
            code, scale = r
            add(word, code, weight * scale)

    for word, syllables, weight in word_entries:
        weight = weight or default_weight
        reading = syllables_reading(syllables)
        if not reading:
            skipped['pinyin'] += 1
            continue
        add_reading(word, reading, weight)

    for word, weight in vocab_entries:
        weight = weight or default_weight
        reading = auto_reading(word, char_codes)
        if not reading:
            skipped['vocab'] += 1
            continue
        add_reading(word, reading, weight)

    return entries, skipped


# ---------------------------------------------------------------------------
# 写出
# ---------------------------------------------------------------------------

DANZI_HEADER = """\
# 键道27C Flow 单字码表（音码 + 1键声母码）
# 由 tools/build_flow_dict.py 自动生成，请勿手工修改
---
name: xkjd27c_flow.danzi
version: "1.1"
sort: by_weight
use_preset_vocabulary: false
...
"""

SHAPE_DICT_HEADER = """\
# 键道27C Flow 纯形码表（shape，aeiov）
# 由 tools/build_flow_dict.py 从原版 buchong「形简/补充提示/部首偏旁」提取
---
name: xkjd27c_flow.shape
version: "1.0"
sort: original
use_preset_vocabulary: false
...
"""

def variant_header(variant, note):
    return (
        '# 键道27C Flow 词库（%s）\n'
        '# 由 tools/build_flow_dict.py 自动生成，请勿手工修改\n'
        '# 2 字：音音全码；3/4 字：首字母；5 字以上：前三首 + 末一首\n'
        '---\n'
        'name: xkjd27c_flow.%s\n'
        'version: "1.2"\n'
        'sort: by_weight\n'
        'use_preset_vocabulary: false\n'
        'import_tables:\n'
        '  - xkjd27c_flow.danzi\n'
        '  - xkjd27c_flow.shape\n'
        '...\n' % (note, variant))


def write_dict(path, header, entries, scale=1.0):
    ordered = sorted(entries.items(), key=lambda kv: (kv[0][1], -kv[1], kv[0][0]))
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(header)
        for (text, code), weight in ordered:
            f.write('%s\t%s\t%s\n' % (text, code, format_weight(weight * scale)))
    return len(ordered)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def find_pinyin_simp(home):
    candidates = [
        '/usr/share/rime-data/pinyin_simp.dict.yaml',
        os.path.join(home, '.config', 'rime', 'pinyin_simp.dict.yaml'),
        os.path.join(home, '.local', 'share', 'fcitx5', 'rime',
                     'pinyin_simp.dict.yaml'),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return None


def rime_ice_files(repo):
    cn = os.path.join(repo, 'cn_dicts')
    return {
        'char': os.path.join(cn, '8105.dict.yaml'),
        'words': [
            os.path.join(cn, 'base.dict.yaml'),
            os.path.join(cn, 'ext.dict.yaml'),
            os.path.join(cn, 'others.dict.yaml'),
        ],
        'tencent': os.path.join(cn, 'tencent.dict.yaml'),
    }


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_repo = os.path.normpath(os.path.join(here, '..', '..', 'rime_jd27c'))
    home = os.path.expanduser('~')

    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--source', default=default_repo,
                        help='rime_jd27c 仓库路径（默认 %(default)s）')
    parser.add_argument('--pinyin-simp', default=None,
                        help='pinyin_simp.dict.yaml 路径')
    parser.add_argument('--no-pinyin-simp-words', action='store_true',
                        help='（已废弃，忽略）')
    parser.add_argument('--words', action='append', default=[],
                        metavar='PATH',
                        help='额外标准拼音词库（词/拼音/权重），可重复')
    parser.add_argument('--rime-ice', default='/tmp/rime-ice', metavar='DIR',
                        help='rime-ice 仓库路径（默认 %(default)s；不存在则只生成 simp）')
    parser.add_argument('--rime-ice-tencent', action='store_true',
                        help='同时引入 rime-ice tencent（无拼音，自动注音）')
    parser.add_argument('--no-align-original', action='store_true',
                        help='不按原版 1 键/2 键首选调整单字权重')
    parser.add_argument('--out', default=os.path.normpath(
                            os.path.join(here, '..', 'rime')),
                        help='输出目录（默认 %(default)s）')
    parser.add_argument('--weight-scale', type=float, default=1.0,
                        help='全局词频缩放（默认 %(default)s）')
    parser.add_argument('--abbrev-weight', type=float, default=1.0,
                        help='简码（3 字以上首字母）词频系数（默认 %(default)s）')
    parser.add_argument('--length-weight', type=float, default=0.35,
                        help='词组按字数降权底数：每多 1 字乘一次（默认 %(default)s，1 = 不降权）')
    parser.add_argument('--initial-weight', type=float, default=1.0,
                        help='1 键声母码词频系数（默认 %(default)s）')
    parser.add_argument('--default-weight', type=float, default=1.0,
                        help='无权重条目的默认词频（默认 %(default)s）')
    args = parser.parse_args()

    pinyin_simp = args.pinyin_simp or find_pinyin_simp(home)
    if not pinyin_simp or not os.path.exists(pinyin_simp):
        sys.exit('找不到 pinyin_simp.dict.yaml，请用 --pinyin-simp 指定')

    # ---------------- 数据源 ----------------
    # 字频/读音权重来自所有来源（danzi 两个变体共用）；词条按变体分开：
    #   simp = pinyin_simp 词（+ --words）
    #   ice  = rime-ice base/ext/others（+ tencent、+ --words）
    char_w = {}
    char_reading_w = {}

    def read_source(path):
        cw, crw, words, vocab, stats = load_dict(path, args.default_weight)
        for ch, w in cw.items():
            char_w[ch] = max(char_w.get(ch, 0.0), w)
        for key, w in crw.items():
            char_reading_w[key] = max(char_reading_w.get(key, 0.0), w)
        print('  %s  (%d 行, 词 %d, 无拼音 %d, 跳过 %d)'
              % (path, stats['rows'], stats['words'],
                 stats['vocab'], stats['skipped']))
        return words, vocab

    print('数据源：')
    simp_words, simp_vocab = read_source(pinyin_simp)

    extra_words, extra_vocab = [], []
    for path in args.words:
        if not os.path.exists(path):
            sys.exit('找不到词库：%s' % path)
        w, v = read_source(path)
        extra_words.extend(w)
        extra_vocab.extend(v)

    ice_words, ice_vocab = [], []
    if args.rime_ice and os.path.isdir(args.rime_ice):
        ice = rime_ice_files(args.rime_ice)
        if os.path.exists(ice['char']):
            read_source(ice['char'])  # 只取字频
        for path in ice['words']:
            if os.path.exists(path):
                w, v = read_source(path)
                ice_words.extend(w)
                ice_vocab.extend(v)
        if args.rime_ice_tencent and os.path.exists(ice['tencent']):
            w, v = read_source(ice['tencent'])
            ice_words.extend(w)
            ice_vocab.extend(v)
    ice_ready = bool(ice_words)
    if not ice_ready:
        print('  未找到 rime-ice 词库（%s），只生成 simp 词库' % args.rime_ice)

    # --words 追加词库两个变体都加
    simp_words.extend(extra_words)
    simp_vocab.extend(extra_vocab)
    ice_words.extend(extra_words)
    ice_vocab.extend(extra_vocab)

    print('  字频 %d 字' % len(char_w))

    zidb_path = os.path.join(args.source, 'Lambda', 'ZiDB', '通常.txt')
    zidb = load_zidb(zidb_path)
    shapes = load_zidb_shapes(zidb_path)
    zidb_static = load_zidb_static(
        os.path.join(args.source, 'Lambda', 'ZiDB', '静态.txt'))

    char_codes = build_char_codes(zidb, zidb_static, char_w,
                                  char_reading_w, args.default_weight)
    danzi = build_danzi(char_codes, args.initial_weight)
    orig_danzi = os.path.join(args.source, 'rime', 'xkjd27c.danzi.dict.yaml')
    if args.no_align_original:
        print('原版首选对齐：已关闭')
    elif os.path.exists(orig_danzi):
        first = load_original_first(orig_danzi)
        changed, missing = align_original_first(danzi, first)
        print('原版首选对齐：%d 个码（调整 %d，缺字 %d）'
              % (len(first), changed, missing))
    else:
        print('原版首选对齐：找不到 %s，跳过' % orig_danzi)
    shape_dict, shape_extras = load_shape_entries(
        os.path.join(args.source, 'rime', 'xkjd27c.buchong.dict.yaml'))
    if shape_extras:
        print('形简段多出来的条目（交给次简表 flow_secondary.lua）：%s'
              % ' '.join(t + c for t, c in shape_extras))

    os.makedirs(args.out, exist_ok=True)
    scale = args.weight_scale
    print('词频缩放系数 %.6g；节奏码 ×%.6g；按字数降权 ×%.6g/字；1 键码 ×%.6g'
          % (scale, args.abbrev_weight, args.length_weight, args.initial_weight))

    n1 = write_dict(os.path.join(args.out, 'xkjd27c_flow.danzi.dict.yaml'),
                    DANZI_HEADER, danzi, scale)
    shape_path = os.path.join(args.out, 'xkjd27c_flow.shape.txt')
    with open(shape_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# 键道27C Flow 期望形码表（ZiDB 前 4 笔画 -> aeiov）\n')
        for char, code in sorted(shapes.items()):
            f.write('%s\t%s\n' % (char, code))

    # 纯形码表（shape）：原版 buchong 的纯形码条目，保持原顺序
    shape_dict_path = os.path.join(args.out, 'xkjd27c_flow.shape.dict.yaml')
    with open(shape_dict_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(SHAPE_DICT_HEADER)
        for text, code in shape_dict:
            f.write('%s\t%s\t1\n' % (text, code))

    # 旧版生成物（cizu / 单一主码表）清理掉，避免混淆
    for stale in ('xkjd27c_flow.cizu.dict.yaml', 'xkjd27c_flow.dict.yaml'):
        p = os.path.join(args.out, stale)
        if os.path.exists(p):
            os.remove(p)

    variants = [('simp', 'pinyin_simp', simp_words, simp_vocab)]
    if ice_ready:
        variants.append(('ice', 'rime-ice', ice_words, ice_vocab))
    for variant, note, words, vocab in variants:
        cizu, skipped = build_cizu(words, vocab, char_codes,
                                   args.abbrev_weight, args.default_weight,
                                   args.length_weight)
        path = os.path.join(args.out, 'xkjd27c_flow.%s.dict.yaml' % variant)
        n = write_dict(path, variant_header(variant, note), cizu, scale)
        print('词库 %s：%d 条（无法注音：拼音词 %d，自动注音 %d）'
              % (variant, n, skipped['pinyin'], skipped['vocab']))

    print('单字 %d 条，纯形码 %d 条，期望形码 %d 字' % (n1, len(shape_dict), len(shapes)))


if __name__ == '__main__':
    main()
