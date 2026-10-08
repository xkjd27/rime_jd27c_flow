#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""键道27C 方案布局表与构建元信息（``build_flow_dict.py --layout``）。

布局表从本方案迁入引擎前的 ``tools/build_flow_dict.py`` 原样搬来
（来源：上游 ``rime_jd27c/Lambda/Layout.py``，另含上游没有的 ``'nve': 'nue'``）。
数据在引擎仓库 ``data/``（ZiDB 取 27C 版，两边共用）。
``SOURCE`` / ``OUT`` 若是相对路径，按本文件所在目录解析。
"""

# ---- 构建元信息 ----
NAME = 'xkjd27c_flow'          # 输出前缀
TITLE = '键道27C Flow'          # 词库文件头里的中文名
SHAPE_SECTION = '形简'          # 上游 补充.txt 里的纯形码段名
SOURCE = 'engine/data'         # 引擎仓库里的数据目录（ZiDB 用 27C 版，共用）
OUT = 'rime'                   # 输出目录

# ---- 布局表（原样搬自旧脚本） ----
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
