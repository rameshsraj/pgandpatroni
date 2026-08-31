#!/bin/bash
# build-docs.sh
# Renders each guide's Mermaid diagrams to PNG and builds a Word (.docx) file.
#
# Requirements: pandoc, @mermaid-js/mermaid-cli (mmdc)
# Usage: bash build-docs.sh

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
MMDC_CFG="$OUT/mermaid-config.json"
PUPPETEER_CFG="$OUT/puppeteer-config.json"

mkdir -p "$OUT"

# Mermaid theme: readable at print size, white background for Word.
cat > "$MMDC_CFG" <<'EOF'
{
  "theme": "base",
  "themeVariables": {
    "fontFamily": "Helvetica, Arial, sans-serif",
    "fontSize": "16px"
  },
  "flowchart": { "useMaxWidth": false, "htmlLabels": true },
  "sequence":  { "useMaxWidth": false },
  "er":        { "useMaxWidth": false }
}
EOF

cat > "$PUPPETEER_CFG" <<'EOF'
{ "args": ["--no-sandbox", "--disable-gpu"] }
EOF

# build_one <project-dir> <source.md> <output-basename> <Document Title>
build_one() {
    local proj="$1" src="$2" base="$3" title="$4"
    local work="$OUT/$base"
    local imgdir="$work/images"
    local md="$work/$base.md"

    echo ""
    echo "=================================================="
    echo "Building: $title"
    echo "=================================================="

    rm -rf "$work"
    mkdir -p "$imgdir"

    # ---- Pass 1: extract mermaid blocks, render PNGs, rewrite markdown ----
    python3 - "$src" "$md" "$imgdir" <<'PYEOF'
import re, sys, pathlib

src, dst, imgdir = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
text = pathlib.Path(src).read_text(encoding="utf-8")

blocks = []
def repl(m):
    idx = len(blocks) + 1
    blocks.append(m.group(1))
    name = f"diagram-{idx:02d}"
    (imgdir / f"{name}.mmd").write_text(m.group(1), encoding="utf-8")
    # Pandoc figure syntax: alt text becomes the caption.
    return f"![Figure {idx}](images/{name}.png)"

text = re.sub(r"```mermaid\n(.*?)\n```", repl, text, flags=re.S)
pathlib.Path(dst).write_text(text, encoding="utf-8")
print(f"  extracted {len(blocks)} mermaid diagram(s)")
PYEOF

    # ---- Pass 2: render each .mmd to PNG ----
    local n=0
    for f in "$imgdir"/*.mmd; do
        [ -e "$f" ] || continue
        n=$((n+1))
        mmdc -i "$f" -o "${f%.mmd}.png" \
             -c "$MMDC_CFG" -p "$PUPPETEER_CFG" \
             -b white -s 2 --quiet
        printf "  rendered %s\n" "$(basename "${f%.mmd}.png")"
    done
    echo "  $n PNG(s) generated"

    # ---- Pass 2b: size each image to fit the Word page ----
    # Pandoc sizes images from raw pixels at 96 DPI, which makes these
    # diagrams spill off the page. Add explicit width/height attributes
    # constrained to the usable text area of a Letter page (1in margins).
    python3 - "$md" "$imgdir" <<'PYEOF'
import re, struct, sys, pathlib

md_path, imgdir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
MAX_W, MAX_H = 6.3, 8.2   # inches of usable space on US Letter

def png_size(p):
    d = p.read_bytes()[:33]
    return struct.unpack(">II", d[16:24])

def fix(m):
    alt, rel = m.group(1), m.group(2)
    png = imgdir / pathlib.Path(rel).name
    if not png.exists():
        return m.group(0)
    w, h = png_size(png)
    scale = min(MAX_W / (w / 96), MAX_H / (h / 96), 1.0)
    return f'![{alt}]({rel}){{width={w/96*scale:.2f}in height={h/96*scale:.2f}in}}'

text = md_path.read_text(encoding="utf-8")
text, n = re.subn(r"!\[([^\]]*)\]\((images/[^)]+)\)", fix, text)
md_path.write_text(text, encoding="utf-8")
print(f"  sized {n} image(s) to fit page")
PYEOF

    # ---- Pass 3: markdown -> docx ----
    ( cd "$work" && pandoc "$base.md" \
        -f gfm+attributes \
        -o "$ROOT/$base.docx" \
        --resource-path=.:images \
        --toc --toc-depth=3 \
        --syntax-highlighting=tango \
        --metadata title="$title" \
        --reference-doc="$OUT/reference.docx" )

    echo "  -> $ROOT/$base.docx"
}

# ---- Create a reference doc so Word styling is sane (landscape-ish margins) ----
if [ ! -f "$OUT/reference.docx" ]; then
    pandoc -o "$OUT/reference.docx" --print-default-data-file reference.docx 2>/dev/null \
      || pandoc --print-default-data-file reference.docx > "$OUT/reference.docx"
fi

build_one \
    "$ROOT/postgres-patroni-ha" \
    "$ROOT/postgres-patroni-ha/docs/POSTGRES_PATRONI_HA_COMPLETE_GUIDE.md" \
    "PostgreSQL-Patroni-HA-Complete-Guide" \
    "PostgreSQL High Availability with Patroni, etcd and HAProxy"

build_one \
    "$ROOT/postgres-sharding-lab" \
    "$ROOT/postgres-sharding-lab/docs/SHARDING_COMPLETE_GUIDE.md" \
    "PostgreSQL-Sharding-Citus-Complete-Guide" \
    "PostgreSQL Sharding with Citus"

echo ""
echo "=================================================="
echo "Done. Word documents:"
ls -lh "$ROOT"/*.docx
echo ""
echo "Diagram PNGs kept in: $OUT/<doc>/images/"
echo "=================================================="
