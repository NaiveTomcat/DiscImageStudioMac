#!/usr/bin/env python3
"""One-off mechanical conversion of the C# EFMPlus tables to Swift.

Reads  src/DvdImageSolver/Encoding/EfmPlusTables.Generated.cs
Writes Sources/DiscImageDvd/EfmPlusTables.swift

Only literal tokens are copied: hex for the words, decimal for the next states.
No table value is authored here.
"""
import re
import sys
from pathlib import Path

SRC = Path.home() / "CodingProjects/DiscImageStudio/src/DvdImageSolver/Encoding/EfmPlusTables.Generated.cs"
DST = Path("/Users/tomdang/CodingProjects/DiscImageStudioMac/Sources/DiscImageDvd/EfmPlusTables.swift")

text = SRC.read_text()
pattern = re.compile(
    r"internal\s+static\s+readonly\s+(\w+)\[\]\s+(\w+)\s*=\s*\[(.*?)\];",
    re.S,
)
found = {}
for match in pattern.finditer(text):
    ctype, name, body = match.group(1), match.group(2), match.group(3)
    raw = re.findall(r"0x[0-9A-Fa-f]+|\b\d+\b", body)
    if ctype == "ushort":
        values = [f"0x{int(token, 0):04X}" for token in raw]
    elif ctype == "byte":
        values = [str(int(token, 0)) for token in raw]
    else:
        sys.exit(f"unexpected element type {ctype}")
    found[name] = values

expected = {
    "MainWords": 1024,
    "MainNextStates": 1024,
    "SubstitutionWords": 352,
    "SubstitutionNextStates": 352,
}
for name, count in expected.items():
    if name not in found:
        sys.exit(f"missing array {name}")
    if len(found[name]) != count:
        sys.exit(f"{name}: expected {count} entries, got {len(found[name])}")

swift_names = {
    "MainWords": ("mainWords", "UInt16"),
    "MainNextStates": ("mainNextStates", "UInt8"),
    "SubstitutionWords": ("substitutionWords", "UInt16"),
    "SubstitutionNextStates": ("substitutionNextStates", "UInt8"),
}

lines = [
    "// EFMPlus 256×4 状态转换表。",
    "//",
    "// 本文件由一次性脚本从源仓库的 C# 生成文件**机械转换**得到（HANDOFF §2.4）：",
    "//   源：src/DvdImageSolver/Encoding/EfmPlusTables.Generated.cs",
    "//   转换：解析 C# 常量数组的十六进制/十进制字面量，按 16 项一行重排为 Swift 数组字面量。",
    "//   原始来源：ECMA-267 Annex G（第 67–74 页），由源项目的 tools/generate_efm_tables.py 生成。",
    "//",
    "// 不要手工编辑、不要凭记忆重建：任何改动都应重跑上面的转换。",
    "// 索引约定与 C# 一致：word/nextState 按 value * 4 + (state - 1) 索引。",
    "",
    "enum EfmPlusTables {",
]
for cs_name, (swift_name, element_type) in swift_names.items():
    values = found[cs_name]
    lines.append(f"    /// {cs_name}（{len(values)} 项）。")
    lines.append(f"    static let {swift_name}: [{element_type}] = [")
    for start in range(0, len(values), 16):
        chunk = ", ".join(values[start:start + 16])
        lines.append(f"        {chunk},")
    lines.append("    ]")
    if cs_name != "SubstitutionNextStates":
        lines.append("")
lines.append("}")
lines.append("")

DST.write_text("\n".join(lines))
print(f"wrote {DST} ({len(lines)} lines)")
for name, values in found.items():
    print(f"  {name}: {len(values)} entries, first={values[0]}, last={values[-1]}")
