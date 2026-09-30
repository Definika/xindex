"""Builds the Xindex v4 hybrid multichain architecture PDF from the text below, which mirrors
design/2026-09-29-v4-hybrid-architecture.md in its own section order: change both together.

Usage: python3 design/build_pdf.py design/2026-09-29-v4-hybrid-architecture.pdf
Needs reportlab (pip install reportlab) and the Arial fonts in /System/Library/Fonts/Supplemental (macOS).
"""
import sys
from reportlab.lib.pagesizes import A4
from reportlab.lib import colors
from reportlab.lib.units import mm
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer, Table, TableStyle,
                                PageBreak, KeepTogether, CondPageBreak)
from reportlab.platypus.flowables import Flowable
from reportlab.graphics.shapes import Drawing, Rect, String, Line, Polygon, Group
from reportlab.graphics import renderPDF

OUT = sys.argv[1]
FD = "/System/Library/Fonts/Supplemental/"
pdfmetrics.registerFont(TTFont("Arial", FD + "Arial.ttf"))
pdfmetrics.registerFont(TTFont("Arial-Bold", FD + "Arial Bold.ttf"))
pdfmetrics.registerFont(TTFont("Arial-Italic", FD + "Arial Italic.ttf"))
pdfmetrics.registerFont(TTFont("Arial-BoldItalic", FD + "Arial Bold Italic.ttf"))
pdfmetrics.registerFontFamily("Arial", normal="Arial", bold="Arial-Bold", italic="Arial-Italic",
                              boldItalic="Arial-BoldItalic")

NAVY = colors.HexColor("#1F3A5F")
TEAL = colors.HexColor("#2A7F9E")
TEAL_L = colors.HexColor("#E3F1F6")
GREY = colors.HexColor("#5B6770")
GREY_L = colors.HexColor("#F3F5F7")
LINE = colors.HexColor("#C9D2DA")
AMBER = colors.HexColor("#B7791F")
AMBER_L = colors.HexColor("#FDF3E1")
RED = colors.HexColor("#B83A3A")
GREEN = colors.HexColor("#2F7D4F")
GREEN_L = colors.HexColor("#E6F3EA")
WHITE = colors.white

W, H = A4
M = 18 * mm
CW = W - 2 * M  # content width

ss = {}
ss["body"] = ParagraphStyle("body", fontName="Arial", fontSize=9.6, leading=13.6, textColor=colors.HexColor("#1D2329"),
                            spaceAfter=5)
ss["small"] = ParagraphStyle("small", parent=ss["body"], fontSize=8.4, leading=11.4, spaceAfter=0)
ss["cell"] = ParagraphStyle("cell", parent=ss["body"], fontSize=8.4, leading=11, spaceAfter=0)
ss["cellb"] = ParagraphStyle("cellb", parent=ss["cell"], fontName="Arial-Bold")
ss["head"] = ParagraphStyle("head", parent=ss["cell"], fontName="Arial-Bold", textColor=WHITE)
ss["h1"] = ParagraphStyle("h1", fontName="Arial-Bold", fontSize=17, leading=21, textColor=NAVY, spaceBefore=4,
                          spaceAfter=8)
ss["h2"] = ParagraphStyle("h2", fontName="Arial-Bold", fontSize=12, leading=15.5, textColor=NAVY, spaceBefore=9,
                          spaceAfter=5)
ss["h3"] = ParagraphStyle("h3", fontName="Arial-Bold", fontSize=10.2, leading=13.5, textColor=TEAL, spaceBefore=6,
                          spaceAfter=3)
ss["bullet"] = ParagraphStyle("bullet", parent=ss["body"], leftIndent=13, bulletIndent=3, spaceAfter=3)
ss["num"] = ParagraphStyle("num", parent=ss["body"], leftIndent=15, bulletIndent=1, spaceAfter=3)
ss["formula"] = ParagraphStyle("formula", parent=ss["body"], fontName="Arial", fontSize=10, leading=15,
                               alignment=TA_CENTER, textColor=NAVY, spaceAfter=0)
ss["callout"] = ParagraphStyle("callout", parent=ss["body"], fontSize=9.2, leading=13, spaceAfter=0)
ss["caption"] = ParagraphStyle("caption", parent=ss["small"], textColor=GREY, alignment=TA_CENTER, spaceBefore=3,
                               spaceAfter=8)
ss["toc"] = ParagraphStyle("toc", parent=ss["body"], fontSize=9.6, leading=15, spaceAfter=0)


def P(t, s="body"):
    return Paragraph(t, ss[s])


def H1(t):
    return [CondPageBreak(60 * mm), P(t, "h1")]


def H2(t):
    return [CondPageBreak(40 * mm), P(t, "h2")]


def H3(t):
    return P(t, "h3")


def bullets(items, style="bullet"):
    return [Paragraph(i, ss[style], bulletText="•") for i in items]


def numbered(items):
    return [Paragraph(i, ss["num"], bulletText=f"{n}.") for n, i in enumerate(items, 1)]


def table(rows, widths, header=True, zebra=True, first_bold=False, align_right=()):
    data = []
    for r, row in enumerate(rows):
        cells = []
        for c, v in enumerate(row):
            if isinstance(v, Flowable):
                cells.append(v)
                continue
            st = "head" if (header and r == 0) else ("cellb" if (first_bold and c == 0) else "cell")
            cells.append(Paragraph(str(v), ss[st]))
        data.append(cells)
    t = Table(data, colWidths=[w * CW for w in widths], repeatRows=1 if header else 0, hAlign="LEFT")
    cmds = [("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 5),
            ("RIGHTPADDING", (0, 0), (-1, -1), 5), ("TOPPADDING", (0, 0), (-1, -1), 3.5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3.5), ("LINEBELOW", (0, 0), (-1, -1), 0.4, LINE)]
    if header:
        cmds += [("BACKGROUND", (0, 0), (-1, 0), NAVY), ("LINEBELOW", (0, 0), (-1, 0), 0, NAVY)]
    if zebra:
        for r in range(1 if header else 0, len(rows)):
            if (r % 2 == 0) == header:
                cmds.append(("BACKGROUND", (0, r), (-1, r), GREY_L))
    t.setStyle(TableStyle(cmds))
    return [t, Spacer(1, 7)]


def boxed(flowables, bg=TEAL_L, border=TEAL, pad=8):
    t = Table([[flowables]], colWidths=[CW])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), bg), ("LINEBEFORE", (0, 0), (0, -1), 3, border),
                           ("LEFTPADDING", (0, 0), (-1, -1), pad + 2), ("RIGHTPADDING", (0, 0), (-1, -1), pad),
                           ("TOPPADDING", (0, 0), (-1, -1), pad - 2), ("BOTTOMPADDING", (0, 0), (-1, -1), pad - 1)]))
    return [t, Spacer(1, 8)]


def formula(*lines):
    return boxed([P(l, "formula") for l in lines], bg=GREY_L, border=NAVY)


def callout(title, text, kind="info"):
    bg, bd = {"info": (TEAL_L, TEAL), "warn": (AMBER_L, AMBER), "ok": (GREEN_L, GREEN)}[kind]
    return boxed([P(f"<b>{title}</b> {text}", "callout")], bg=bg, border=bd)


class Draw(Flowable):
    def __init__(self, d):
        super().__init__()
        self.d = d
        self.width, self.height = d.width, d.height

    def draw(self):
        renderPDF.draw(self.d, self.canv, 0, 0)


def box(g, x, y, w, h, title, lines=(), fill=WHITE, stroke=NAVY, tcol=NAVY, fs=8.2, lfs=7.2, r=4):
    g.add(Rect(x, y, w, h, rx=r, ry=r, fillColor=fill, strokeColor=stroke, strokeWidth=0.9))
    ty = y + h - 11
    g.add(String(x + w / 2, ty, title, fontName="Arial-Bold", fontSize=fs, fillColor=tcol, textAnchor="middle"))
    for i, l in enumerate(lines):
        g.add(String(x + w / 2, ty - 10.5 - i * 9.2, l, fontName="Arial", fontSize=lfs, fillColor=GREY,
                     textAnchor="middle"))


def arrow(g, x1, y1, x2, y2, col=TEAL, w=1.1, head=5):
    g.add(Line(x1, y1, x2, y2, strokeColor=col, strokeWidth=w))
    import math
    a = math.atan2(y2 - y1, x2 - x1)
    p1 = (x2 - head * math.cos(a - 0.4), y2 - head * math.sin(a - 0.4))
    p2 = (x2 - head * math.cos(a + 0.4), y2 - head * math.sin(a + 0.4))
    g.add(Polygon([x2, y2, p1[0], p1[1], p2[0], p2[1]], fillColor=col, strokeColor=col, strokeWidth=0.5))


def label(g, x, y, t, fs=7.2, col=GREY, anchor="middle", bold=False):
    g.add(String(x, y, t, fontName="Arial-Bold" if bold else "Arial", fontSize=fs, fillColor=col, textAnchor=anchor))


# ---------------------------------------------------------------- diagrams
def diagram_architecture():
    w, h = CW, 262
    d = Drawing(w, h)
    # Ethereum frame
    ex, ey, ew, eh = 0, 122, w, 138
    d.add(Rect(ex, ey, ew, eh, rx=6, ry=6, fillColor=TEAL_L, strokeColor=TEAL, strokeWidth=1))
    label(d, ex + 10, ey + eh - 14, "ETHEREUM", fs=9, col=TEAL, anchor="start", bold=True)
    bw, bh, gap = (ew - 40) / 3, 44, 10
    comps = [("IndexFactory", ["lists chains and tokens (timelocked)", "creates indexes (CREATE2)"]),
             ("IndexHub  (one per index)", ["ERC-20 shares · Tier 1 coins", "mirror · orders · burns · auction"]),
             ("StateVerifiers", ["one per vault chain, one system:", "proves that chain's vault state"]),
             ("MintRequests", ["USDC/USDT in and out", "filled by minters"]),
             ("IndexZap", ["one-click for Ethereum-only", "indexes (≤ ~35 tokens)"]),
             ("Owner Safe · Guardian", ["timelocked governance", "veto · cancel · freeze"])]
    for i, (t, ls) in enumerate(comps):
        cx = ex + 10 + (i % 3) * (bw + gap)
        cy = ey + eh - 30 - bh - (i // 3) * (bh + 12)
        box(d, cx, cy, bw, bh, t, ls, fill=WHITE)
    # vaults
    vw, vh = (w - 3 * 12) / 4, 58
    vaults = [("Vault · BNB Chain", ["BNB"]), ("Vault · Solana", ["SOL"]),
              ("Vault · Tron", ["TRX"]), ("Vault · HyperEVM · …", ["HYPE · one per chain"])]
    vy = 34
    for i, (t, ls) in enumerate(vaults):
        vx = i * (vw + 12)
        box(d, vx, vy, vw, vh, t, ls + ["P1 + P2 Ethereum verifiers", "no owner · speed limit"], fill=WHITE,
            stroke=NAVY)
    # arrows
    for i in range(4):
        cx = i * (vw + 12) + vw / 2
        arrow(d, cx - 14, vy + vh + 2, cx - 14, ey - 3, col=GREEN)
        arrow(d, cx + 14, ey - 3, cx + 14, vy + vh + 2, col=NAVY)
    # legend
    arrow(d, 4, 18, 4, 28, col=GREEN)
    label(d, 11, 20, "vault state to Ethereum (one system per chain)", col=GREEN, anchor="start", fs=7.4, bold=True)
    arrow(d, w * 0.47, 28, w * 0.47, 18, col=NAVY)
    label(d, w * 0.47 + 7, 20, "Ethereum to vaults (coins out: P1 AND P2 · protect: P1 OR P2)", col=NAVY,
          anchor="start", fs=7.4, bold=True)
    label(d, w / 2, 3, "Off-chain, open to anyone: minters · provers · rebalance executors · watchers · the app",
          fs=7.6, col=GREY)
    return [Draw(d), P("Figure 1. The hub on Ethereum and one ownerless vault per chain, joined only by proofs. The "
                       "two Ethereum proof systems are shared by every chain.", "caption")]


def diagram_mint():
    w, h = CW, 278
    d = Drawing(w, h)
    lanes = ["Minter", "IndexHub (Ethereum)", "Vaults (other chains)", "Provers"]
    lx = [w * 0.1, w * 0.37, w * 0.66, w * 0.9]
    for x, t in zip(lx, lanes):
        d.add(Rect(x - 52, h - 22, 104, 18, rx=3, ry=3, fillColor=NAVY, strokeColor=NAVY))
        label(d, x, h - 16, t, fs=7.6, col=WHITE, bold=True)
        d.add(Line(x, h - 24, x, 8, strokeColor=LINE, strokeWidth=1, strokeDashArray=[3, 3]))
    steps = [(0, 1, "1. openOrder(N): Ethereum coins into escrow, amounts fixed, deadline"),
             (0, 2, "2. buy anywhere, withdraw natively, deposit(order) → pending"),
             (3, 1, "3. VaultState proof (the chain's one system)"),
             (1, 1, "4. settle: invariant + mint cap → claimable in 24h"),
             (1, 2, "5. OrderSettled → pending moves into the index"),
             (1, 0, "6. claim() after the 24-hour lock → shares"),
             (1, 2, "✕ deadline missed: failOrder → escrow back, OrderFailed → refund"),
             (3, 1, "✕ shortfall or conflicting proof in the lock: voided at once")]
    y = h - 44
    for a, b, t in steps:
        col = RED if t.startswith("✕") else TEAL
        t = t.replace("✕", "×")
        tw = pdfmetrics.stringWidth(t, "Arial", 7.3)
        if a == b:
            d.add(Rect(lx[a] - 4, y - 5, 8, 10, fillColor=col, strokeColor=col))
            d.add(Rect(lx[a] + 8, y - 5, tw + 4, 10, fillColor=WHITE, strokeColor=None))
            label(d, lx[a] + 10, y - 2.5, t, anchor="start", fs=7.3, col=colors.HexColor("#1D2329"))
        else:
            arrow(d, lx[a], y, lx[b], y, col=col)
            mid = (lx[a] + lx[b]) / 2
            d.add(Rect(mid - tw / 2 - 2, y + 2, tw + 4, 10, fillColor=WHITE, strokeColor=None))
            label(d, mid, y + 4.5, t, fs=7.3, col=colors.HexColor("#1D2329"))
        y -= 29
    return [Draw(d), P("Figure 2. A mint: every token is deposited and proven before shares exist, new shares "
                       "stay locked for 24 hours, and a proven shortfall voids the order automatically.", "caption")]


def diagram_redeem():
    w, h = CW, 128
    d = Drawing(w, h)
    specs = [("Holder", ["burns N shares"], GREY_L, NAVY, NAVY, 70),
             ("IndexHub", ["pays Tier 1 coins at once", "emits Burn per chain"], TEAL_L, TEAL, NAVY, 112),
             ("Prover", ["anyone, after", "Ethereum finality"], GREY_L, NAVY, NAVY, 88),
             ("Vault", ["verifies, pays,", "marks nonce used"], WHITE, NAVY, NAVY, 88),
             ("Recipient", ["on that chain"], GREEN_L, GREEN, GREEN, 76)]
    gap = (w - sum(s[5] for s in specs)) / (len(specs) - 1)
    x, xs = 0, []
    for t, ls, fill, stroke, tcol, bw in specs:
        box(d, x, 50, bw, 40, t, ls, fill=fill, stroke=stroke, tcol=tcol)
        xs.append((x, bw))
        x += bw + gap
    for i in range(len(xs) - 1):
        arrow(d, xs[i][0] + xs[i][1], 70, xs[i + 1][0], 70, col=GREEN if i == len(xs) - 2 else TEAL)
    hx = xs[1][0] + xs[1][1] / 2
    arrow(d, hx, 50, hx, 24, col=GREEN)
    label(d, hx, 13, "Tier 1 coins (WBTC, WETH, LINK, …) to the holder immediately", fs=7.3, col=GREEN)
    label(d, w / 2, 104, "≈ 15–30 min per chain · above 4% of a vault per day, payouts wait in a queue", fs=7.3,
          col=GREY)
    return [Draw(d), P("Figure 3. An in-kind redemption. Any chain can be skipped and collected later; nothing expires.",
                       "caption")]


def diagram_layers():
    w, h = CW, 175
    d = Drawing(w, h)
    rows = [("Layer 1 · Prevention", "Fork-aware verifiers, rotated 90 days before every scheduled upgrade", GREEN_L,
             GREEN),
            ("Layer 2 · Fail closed", "An unknown format is rejected: payouts can stop, never go to the wrong person",
             TEAL_L, TEAL),
            ("Layer 3 · Stall-gated recovery", "After 7 days of stall: successor proposed, continuity test, 30 days of "
                                               "review, ≤ 2 guardian vetoes", AMBER_L, AMBER),
            ("Layer 4 · Snapshot exit", "After 180 days: holders at the last verified checkpoint are paid directly",
             colors.HexColor("#F7E4E4"), RED)]
    y = h - 30
    for t, s, bg, bd in rows:
        d.add(Rect(0, y, w, 26, rx=3, ry=3, fillColor=bg, strokeColor=bd, strokeWidth=0.8))
        label(d, 8, y + 9.5, t, anchor="start", fs=8.2, col=bd, bold=True)
        label(d, 150, y + 9.5, s, anchor="start", fs=7.6, col=colors.HexColor("#1D2329"))
        y -= 31
    # timeline
    ty = 16
    d.add(Line(20, ty, w - 10, ty, strokeColor=NAVY, strokeWidth=1.2))
    marks = [(0, "break"), (7, "stall mode"), (37, "resume (no vetoes)"), (97, "resume (2 vetoes)"),
             (180, "snapshot exit")]
    for dday, t in marks:
        x = 20 + (w - 40) * dday / 180
        d.add(Line(x, ty - 4, x, ty + 4, strokeColor=NAVY, strokeWidth=1.2))
        anchor = "end" if dday == 0 else ("start" if dday == 7 else "middle")
        dx = -2 if dday == 0 else (2 if dday == 7 else 0)
        label(d, x + dx, ty + 7, f"day {dday}", fs=6.8, col=NAVY, bold=True, anchor=anchor)
        label(d, x + dx, ty - 12, t, fs=6.8, col=GREY, anchor=anchor)
    return [Draw(d), P("Figure 4. Four layers turn an unexpected Ethereum format change into a bounded delay.",
                       "caption")]


def diagram_stages():
    w, h = CW, 120
    d = Drawing(w, h)
    stages = [("A", "WBTC, ETH, LINK, WBT, UNI", 79.8, 4.2), ("B", "A + BNB, SOL, TRX, HYPE", 88.6, 3.1),
              ("C", "B + 5 more chains' coins", 89.9, 2.6)]
    x0, bwmax = 150, w - 260
    for i, (s, t, cov, te) in enumerate(stages):
        y = h - 30 - i * 34
        label(d, 0, y + 4, f"Stage {s}", anchor="start", fs=8.4, col=NAVY, bold=True)
        label(d, 42, y + 4, t, anchor="start", fs=7.4, col=GREY)
        d.add(Rect(x0, y, bwmax, 14, fillColor=GREY_L, strokeColor=LINE, strokeWidth=0.4))
        d.add(Rect(x0, y, bwmax * cov / 100, 14, fillColor=TEAL, strokeColor=TEAL))
        label(d, x0 + bwmax * cov / 100 - 4, y + 3.8, f"{cov}%", anchor="end", fs=7.6, col=WHITE, bold=True)
        label(d, x0 + bwmax + 10, y + 4, f"tracking error {te}%/yr", anchor="start", fs=7.6, col=NAVY)
    label(d, x0 + bwmax / 2, 2, "share of the top 100's value (without stablecoins and wrapped copies)", fs=7,
          col=GREY)
    return [Draw(d), P("Figure 5. Coverage and one-year tracking error by build stage under the 0.2% weight floor "
                       "(backtest to 29 Sep 2026).", "caption")]


# ---------------------------------------------------------------- page templates
def on_cover(c, doc):
    c.saveState()
    c.setFillColor(NAVY)
    c.rect(0, H - 118 * mm, W, 118 * mm, fill=1, stroke=0)
    c.setFillColor(TEAL)
    c.rect(0, H - 121 * mm, W, 3 * mm, fill=1, stroke=0)
    c.setFillColor(WHITE)
    c.setFont("Arial", 10)
    c.drawString(M, H - 30 * mm, "XINDEX · DESIGN PROPOSAL · 29 SEPTEMBER 2026 · REVISED 30 SEPTEMBER 2026")
    c.setFont("Arial-Bold", 30)
    c.drawString(M, H - 55 * mm, "Xindex v4")
    c.setFont("Arial-Bold", 19)
    c.drawString(M, H - 67 * mm, "The hybrid multichain index")
    c.setFont("Arial", 11.5)
    c.drawString(M, H - 82 * mm, "How one ERC-20 can hold the largest crypto assets in kind,")
    c.drawString(M, H - 88.5 * mm, "across chains, with no custodian inside the protocol.")
    c.setFont("Arial", 8.5)
    c.setFillColor(colors.HexColor("#C9D6E3"))
    c.drawString(M, H - 108 * mm, "Status: proposal. Nothing described here is implemented. Measurements dated "
                                  "29 Sep 2026; re-measure before fixing any parameter.")
    c.restoreState()
    footer(c, doc, cover=True)


def footer(c, doc, cover=False):
    c.saveState()
    c.setStrokeColor(LINE)
    c.setLineWidth(0.5)
    c.line(M, 12 * mm, W - M, 12 * mm)
    c.setFont("Arial", 7.5)
    c.setFillColor(GREY)
    c.drawString(M, 8 * mm, "Xindex v4 · hybrid multichain architecture · design proposal, revised 30 Sep 2026")
    c.drawRightString(W - M, 8 * mm, f"{doc.page}")
    if not cover:
        c.setFillColor(TEAL)
        c.rect(M, H - 11 * mm, 14 * mm, 1.2 * mm, fill=1, stroke=0)
    c.restoreState()


doc = BaseDocTemplate(OUT, pagesize=A4, leftMargin=M, rightMargin=M, topMargin=16 * mm, bottomMargin=18 * mm,
                      title="Xindex v4: hybrid multichain architecture", author="Xindex",
                      subject="Architecture of the hybrid multichain index model (design proposal)")
cover_frame = Frame(M, 18 * mm, CW, H - 18 * mm - 128 * mm, id="cover")
body_frame = Frame(M, 18 * mm, CW, H - 34 * mm, id="body")
doc.addPageTemplates([PageTemplate(id="cover", frames=[cover_frame], onPage=on_cover),
                      PageTemplate(id="body", frames=[body_frame], onPage=footer)])

from reportlab.platypus import NextPageTemplate

S = []


def tile(big, small, col=NAVY):
    return [Paragraph(f"<font size=17><b>{big}</b></font>", ParagraphStyle("t", parent=ss["body"], textColor=col,
                                                                           leading=21, spaceAfter=1)),
            Paragraph(small, ss["small"])]


tiles = Table([[tile("14", "tokens held in kind:<br/>WBTC, WETH, 3 Ethereum<br/>tokens, 9 chains' coins"),
                tile("89.9%", "of the top 100's value<br/>(without stablecoins and<br/>wrapped copies)"),
                tile("2.6%", "tracking error per year<br/>against the top 100<br/>(one-year backtest)"),
                tile("≤ 0.5%", "of an index per day: the most<br/>any single failure can cost<br/>(WBTC excepted)",
                     col=GREEN)]], colWidths=[CW / 4] * 4)
tiles.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LINEBEFORE", (1, 0), (-1, -1), 0.5, LINE),
                           ("LEFTPADDING", (0, 0), (-1, -1), 8), ("TOPPADDING", (0, 0), (-1, -1), 2)]))
S += [Spacer(1, 4), tiles, Spacer(1, 16)]
S += [P("Contents", "h2")]
toc = ["1. Summary", "2. Why a new model", "3. Which assets it holds", "4. Architecture at a glance",
       "5. Components", "6. Data model and cross-chain messages", "7. How it works: the flows",
       "8. Accounting and invariants", "9. Security model", "10. Surviving upgrades",
       "11. Scale, liquidity and reliability", "12. Valuing the index", "13. Trade-offs",
       "14. Parameters", "15. Recorded decisions and funding", "16. Build stages and verification",
       "17. Open questions", "Appendix: data sources"]
half = (len(toc) + 1) // 2
tt = Table([[P("<br/>".join(toc[:half]), "toc"), P("<br/>".join(toc[half:]), "toc")]], colWidths=[CW / 2] * 2)
tt.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 0)]))
S += [tt, NextPageTemplate("body"), PageBreak()]

# ---------------------------------------------------------------- 1 summary
S += H1("1. Summary")
S += [P("Xindex v3 holds only tokens that exist on Ethereum, prices them with Chainlink and allows up to 20 of them. "
        "That rules out a broad top-100 index: most of the market's value lives on other chains, most tokens have no "
        "Chainlink feed on Ethereum, and one-click minting of many tokens does not fit in a transaction.")]
S += [P("<b>v4 keeps one ERC-20 per index and holds every asset in kind, where it naturally lives:</b>")]
S += bullets([
    "<b>On Ethereum:</b> WBTC, WETH and the tokens native to Ethereum sit in the index contract itself, exactly as in "
    "v3.",
    "<b>On other smart-contract chains:</b> native BNB, SOL, TRX, HYPE and others sit in <b>ownerless vault "
    "contracts</b> on their own chains. A vault pays out only against a cryptographic proof of what happened on "
    "Ethereum, so no person or company holds their keys.",
    "<b>No prices where money moves:</b> units follow market caps through <i>units = k × supply</i>, so prices "
    "cancel out, and rebalancing auctions are bounded by supply ratios alone.",
    "<b>Minters</b> (market makers) create and redeem shares in kind across chains; everyone else buys and sells the "
    "index token on Uniswap or through mint and redeem requests, without leaving Ethereum.",
    "<b>The bounded-loss standard:</b> no single failure in anything v4 builds can cost holders more than about 0.5% "
    "of an index per day, anyone can check everything, and holders can always take the rest out.",
    "<b>A weight floor keeps it practical:</b> the flagship index holds the 14 tokens above 0.2% of the market that "
    "pass the liquidity screen, 89.9% of the value on 9 vault chains, instead of all 54 holdable tokens on 22."])
S += callout("The one exception.", "Bitcoin's chain cannot verify proofs, so Bitcoin enters as WBTC, whose custodian "
             "holds 73–83% of an index's value. The owner accepted this on 29 Sep 2026 (\"WBTC only for now\"); "
             "section 9.4 shows the measured options for later.", "warn")
S += callout("Revised 30 Sep 2026 after an external review:", "two proof systems only where coins leave a vault; the "
             "0.2% weight floor; upgrade prevention for vault chains too; weekly supply updates; a units-anchored "
             "rebalance formula that corrects the first draft's; automatic voiding, look-through snapshot claims, "
             "concentration caps and in-place migration; 4% daily limits; funding set out as an open decision. The "
             "owner decided on 30 Sep 2026 that v4 replaces v3.", "info")

# ---------------------------------------------------------------- 2 why
S += H1("2. Why a new model")
S += [P("A literal top-100 index fails on four walls in v3, each measured on 29 September 2026:")]
S += table([["Wall", "What stops it", "Measured"],
            ["Contract limit", "<i>MAX_COMPONENTS</i> = 20 in the factory, a constant", "20 tokens"],
            ["Gas", "EIP-7825 caps a transaction at 2<super>24</super> ≈ 16.8M gas; a one-click mint costs about 265k–"
                    "430k gas per token", "one-click tops out near 40–60 tokens"],
            ["Universe", "A component must be an ERC-20 on Ethereum with a Chainlink feed and Uniswap depth",
             "only 8 of the top 100 qualify"],
            ["Membership", "Constituents are fixed at creation, while the top 100 changes", "—"]],
           [0.18, 0.55, 0.27], first_bold=True)
S += [P("The deciding question is custody. Index shares change hands freely, so when a coin is deposited nobody knows "
        "who will eventually redeem it. On a chain that cannot check anything about Ethereum, coins move only with a "
        "signature, and a signature made in advance must name its recipient, so someone has to sign at redemption time "
        "and that someone is a custodian. On a chain that can verify a proof, a contract takes the signer's place.")]
S += formula("<b>A coin can be held with no custodian if and only if its own chain can verify a proof about "
             "Ethereum.</b>")
S += [P("v4 is built on that rule: it holds everything that can be held without a custodian, and admits exactly one "
        "custodian, WBTC, for the asset whose chain cannot.")]

# ---------------------------------------------------------------- 3 assets
S += H1("3. Which assets it holds")
S += [P("The top 100 by market cap on 29 Sep 2026, without stablecoins, gold and wrapped or staked copies, leaves 66 "
        "assets. They fall into three tiers:")]
S += table([["Tier", "Where the coins live", "Assets", "Share of value"],
            ["1", "Ethereum, in the index contract", "24: ETH, LINK, UNI, AAVE, SHIB, PEPE, ENA, ONDO, …", "15.8%"],
            ["2", "A vault on their own smart-contract chain", "29: BNB, SOL, TRX, HYPE, ADA, XLM, NEAR, AVAX, SUI, "
                                                                 "TON, …", "11.5%"],
            ["3", "Script-only chains (out of scope)", "9: BTC (65.8%), XRP, ZEC, DOGE, XMR, BCH, LTC, KAS, DASH",
             "72.1%"]], [0.07, 0.3, 0.46, 0.17], first_bold=True)
S += [P("Bitcoin enters Tier 1 as WBTC. Holding everything that can be held, 54 tokens, would cover 93.1% of the "
        "value at 2.0% tracking error a year, but it needs 22 vault chains, and most of those tokens weigh under 0.1%.")]
S += H2("3.1 The weight floor")
S += [P("A small weight still costs a minter a native withdrawal, a deposit and a proof on its own chain for every mint: "
        "a $250k mint needs about $125 of the smallest coin, and fewer minters means a wider spread on the index "
        "token. The flagship index holds only tokens weighing at least <b>0.2%</b> that also pass the liquidity screen "
        "(daily volume at least 0.1% of market cap):")]
S += table([["Weight floor", "Tokens", "Coverage", "Tracking error/yr", "Vault chains"],
            ["none", "54", "93.1%", "2.0%", "22"],
            ["0.1%", "28", "91.8%", "2.3%", "14"],
            ["<b>0.2%</b>", "<b>15</b>", "<b>90.2%</b>", "<b>2.6%</b>", "<b>9</b>"],
            ["0.5%", "6", "87.5%", "3.2%", "4 (BNB Chain, HyperEVM, Solana, Tron)"]],
           [0.16, 0.12, 0.14, 0.2, 0.38], first_bold=True)
S += table([["Token", "Weight", "Held on", "Token", "Weight", "Held on"],
            ["WBTC", "73.0%", "Ethereum", "ADA", "0.42%", "Cardano"],
            ["ETH", "14.4%", "Ethereum", "LEO", "0.36%", "Ethereum: <b>fails the screen</b>"],
            ["BNB", "4.4%", "BNB Chain", "XLM", "0.35%", "Stellar"],
            ["SOL", "3.1%", "Solana", "NEAR", "0.28%", "NEAR"],
            ["TRX", "1.4%", "Tron", "UNI", "0.24%", "Ethereum"],
            ["HYPE", "0.85%", "HyperEVM", "HBAR", "0.21%", "Hedera"],
            ["LINK", "0.49%", "Ethereum", "AVAX", "0.21%", "Avalanche"],
            ["WBT", "0.43%", "Ethereum", "", "", ""]],
           [0.11, 0.11, 0.22, 0.11, 0.11, 0.34])
S += [P("LEO trades 0.006% of its market cap a day, so the flagship holds <b>14 tokens: 89.9% of the value at 2.6% a "
        "year</b>, and the smallest coin in a $250k mint is about $530. It is built in three stages, each of which "
        "works on its own:")]
S += diagram_stages()
S += table([["Stage", "Holds", "Tokens", "Coverage", "Tracking error/yr", "WBTC share", "Vault share"],
            ["A", "WBTC, ETH, LINK, WBT, UNI", "5", "79.8%", "4.2%", "82.5%", "0"],
            ["B", "A + BNB, SOL, TRX, HYPE", "9", "88.6%", "3.1%", "74.3%", "9.9%"],
            ["C", "B + ADA, XLM, NEAR, HBAR, AVAX", "14", "89.9%", "2.6%", "73.2%", "11.2%"]],
           [0.08, 0.3, 0.08, 0.11, 0.15, 0.13, 0.15], first_bold=True)
S += [P("Vault share is the part of the index held in vaults; every per-day bound in section 9 is a vault share times "
        "a daily limit. WBT is listed subject to a check of its admin powers, float and Ethereum depth; without it "
        "Stage A holds 4 tokens.")]
S += callout("The backtest understates tracking error.", "It held today's supplies constant, so it measures drift "
             "from price moves only. Tokens whose supply grows through unlocks drift as well, which weekly supply "
             "updates follow (7.6); a re-run with real supply histories is an open task.", "warn")

# ---------------------------------------------------------------- 4 architecture
S += [CondPageBreak(60 * mm), KeepTogether([P("4. Architecture at a glance", "h1")] + diagram_architecture())]
S += H2("4.1 Trust boundaries")
S += table([["Party", "Can do", "Cannot do"],
            ["Contracts (hub, vaults, verifiers)", "Move coins exactly as proofs and invariants allow", "Anything else"],
            ["Owner Safe", "List chains and tokens; propose weekly reference supplies and caps (timelocked, guardian "
                           "veto); rotate a vault's Ethereum verifiers after 30 days, a chain's state verifier after 2; "
                           "after a 7-day stall, propose a successor verifier that must pass a continuity test and 30 "
                           "days of review",
             "Move funds; change an existing index's tokens, units rule or vault addresses; manufacture a stall"],
            ["Guardian", "Veto listings, cancel rebalances, freeze a vault (the freeze expires by itself)",
             "Move funds; unfreeze early"],
            ["Minters, provers, executors", "Deliver coins and proofs; earn spreads and auction discounts",
             "Receive anything they have not paid for first"],
            ["WBTC's custodian", "Hold the Bitcoin behind WBTC", "— (outside the protocol)"]],
           [0.22, 0.46, 0.32], first_bold=True)

# ---------------------------------------------------------------- 5 components
S += H1("5. Components")
S += H2("5.1 IndexFactory (Ethereum)")
S += bullets([
    "<b>Chain registry:</b> a vault chain is linked by a timelocked proposal naming its vault and its state verifier "
    "on Ethereum (listing delay, guardian veto). During the delay anyone checks the vault's code against the audited "
    "build and its fixed settings.",
    "<b>Token registry:</b> each token is listed with its chain, identifier, decimals, a dated reference supply and a "
    "quantity cap.",
    "<b>Supply batches:</b> one week's reference supplies are proposed as a single batch that executes all or nothing "
    "after the listing delay, one batch at a time, each supply within 0.5% of the figure in force. A half-executed "
    "batch could turn a uniform revision into a trade.",
    "<b>Creation:</b> <i>createIndex(name, symbol, tokens, k)</i> sets each token's units from <i>k × supply</i>, "
    "copies each chain's vault address into the index and deploys it at a CREATE2 address over the <b>computed "
    "units</b>, so the address commits to the basket itself. No price is read. Up to 100 tokens per index."])
S += H2("5.2 IndexHub (Ethereum, one per index)")
S += bullets([
    "The ERC-20 shares: the only place shares exist. Transfers never touch another chain.",
    "Tier 1 coins in real balances, issued and redeemed atomically as in v3, with v3's skip-and-claim for a frozen "
    "or paused token.",
    "The <b>mirror</b>: for each vault token, the last proven balance and paid total, plus the hub's own running "
    "total of burns.",
    "Mint orders, burns, the rebalancing auction, the mint cap and a per-chain freeze flag."])
S += H2("5.3 Vault (one per chain, shared by all indexes)")
S += bullets([
    "Holds native coins and the chain's listed tokens in a separate balance for each index, and per order while a "
    "mint is open.",
    "Pays out only against proven Ethereum messages, within a speed limit, and marks each message as used.",
    "Coins sent to it without a deposit call are never credited to any index.",
    "Moves the coins two index versions share from one index to the other on a proven Migrate message, and after a "
    "snapshot exit refuses every burn issued later.",
    "Immutable code with no owner. Its P1 and P2 verifiers change only through a proven rotation or, after a stall, "
    "the continuity-tested recovery of section 10. A guardian address can freeze it and do nothing else."])
S += H2("5.4 Verifiers: two systems where coins leave, one for deposits")
S += bullets([
    "<b>Ethereum → vault chain: two independent proof systems, P1 and P2</b>, from different teams and proving stacks, "
    "each proving an event of the hub or factory in a block with <b>full finality</b>. The statement is about "
    "Ethereum alone, so the same two systems serve every chain: each vault runs a P1 and a P2 verifier. The smaller "
    "sync committee alone is not accepted, because its members are not penalized for signing a false header.",
    "<b>Vault chain → Ethereum: one system per chain</b>, proving the vault's per-index state at a block that is "
    "final under that chain's rules. A forged state can only make a mint look backed, which the 24-hour lock, the "
    "mint cap and the real Ethereum balances already contain.",
    "<b>Conflicting proofs are evidence:</b> two valid proofs of different states for the same vault and height void "
    "every order resting on either and freeze that chain's mints.",
    "<b>Count:</b> Stage B needs 6 proving systems (2 shared + 4 chains) instead of about 10; the floor list needs 11 "
    "instead of 20."])
S += formula("Coins leaving a vault need <b>P1 AND P2</b>.  Protecting (freeze, lower a cap) needs <b>P1 OR P2</b>.",
             "Breaking one Ethereum-side system can stop coins moving; it cannot move them.")
S += callout("Fallback, if full-finality proofs prove impractical:", "the sync committee plus a challenge delay on "
             "every payout and lower caps, a weaker trust assumption stated as such: bribing 342 of 512 unslashable "
             "members replaces a circuit bug as the way in, so the worst case becomes 0 if anyone challenges within "
             "the delay and about 0.45% a day if nobody does. Adopting it is the owner's call.", "warn")
S += H2("5.5 MintRequests, IndexZap and off-chain actors")
S += bullets([
    "<b>MintRequests:</b> a user escrows USDC or USDT with a minimum number of shares; any minter fills it by "
    "delivering the shares in the same transaction; otherwise it is refunded at the deadline. Redemption requests "
    "mirror it. No price is read.",
    "<b>IndexZap:</b> v3's one-click zap, kept for indexes held entirely on Ethereum, up to about 35 tokens "
    "(EIP-7825 caps a transaction at 16.8M gas)."])
S += table([["Actor (anyone)", "Job", "Paid by"],
            ["Minter", "Buys tokens anywhere, deposits in kind, redeems and sells", "Spread between price and value"],
            ["Prover", "Generates proofs with open-source software on ordinary or rented GPUs",
             "Whoever needs the proof"],
            ["Rebalance executor", "Delivers bought tokens first, collects sold tokens after", "The auction's discount"],
            ["Watcher", "Recomputes every vault against the mirror; submits shortfall evidence", "Public good"],
            ["App", "Publishes index value, suggests request limits, routes users", "—"]],
           [0.2, 0.52, 0.28], first_bold=True)

# ---------------------------------------------------------------- 6 data model
S += H1("6. Data model and cross-chain messages")
S += H2("6.1 What each side stores")
S += table([["IndexHub (per index)", "Vault (per chain)"],
            ["Components (chain, token id, decimals) and units", "Settled balance per index and token"],
            ["Each chain's vault address, fixed at creation", "Deposits locked to each open order, and their depositor"],
            ["Last proven settled balance and paid total per vault token", "Total paid per index and token; each "
                                                                            "message nonce usable once"],
            ["Running total of burns per chain and token; next nonce", "Rolling 24-hour outflow (speed limit)"],
            ["Mint orders and their state; rolling mint window", "Quantity cap per token"],
            ["Claims for skipped Tier 1 tokens; freeze flag per chain", "Current P1 and P2 verifiers, freeze "
                                                                         "address, freeze state"],
            ["Rebalance ratios and λ band; contract holders' recovery addresses", "Snapshot checkpoint, if an exit "
                                                                                  "began"]],
           [0.5, 0.5])
S += H2("6.2 Messages between chains")
S += table([["Message", "Direction", "Proof", "Effect"],
            ["VaultState", "vault → Ethereum", "the chain's system", "Settles a mint order; confirms rebalance "
                                                                      "deliveries; refreshes the mirror"],
            ["Shortfall, or a conflicting VaultState", "vault → Ethereum", "the chain's system", "Voids the orders "
             "resting on it and freezes the chain's mints, in the same transaction"],
            ["Burn", "Ethereum → vault", "P1 AND P2", "Pays a redeemer or a rebalance executor"],
            ["OrderSettled / OrderFailed", "Ethereum → vault", "P1 AND P2", "Moves pending coins into the index / "
                                                                            "refunds the depositor"],
            ["RebalanceFailed", "Ethereum → vault", "P1 AND P2", "Refunds an executor's deliveries"],
            ["Migrate", "Ethereum → vault", "P1 AND P2", "Moves coins two versions share to the new version"],
            ["CapUpdate", "Ethereum → vault", "raise AND · lower OR", "Adjusts a quantity cap"],
            ["Freeze", "Ethereum → vault", "P1 OR P2", "Freezes the vault (the guardian can also freeze directly)"],
            ["VerifierRotation", "Ethereum → vault", "P1 AND P2", "Installs a new verifier after 30 days"]],
           [0.22, 0.17, 0.17, 0.44], first_bold=True)
S += [P("Every message names its source chain, destination chain, vault and index, so no proof can be replayed "
        "anywhere else.")]

# ---------------------------------------------------------------- 7 flows
S += H1("7. How it works: the flows")
S += H2("7.1 Setup (once)")
S += numbered(["Deploy the factory, hub template, verifiers, MintRequests and zap on Ethereum, none upgradeable.",
               "Deploy one vault per chain with fixed settings and remove any upgrade authority.",
               "Link each chain through the timelocked proposal; anyone checks the code during the delay.",
               "List tokens with dated reference supplies and quantity caps. A liquidity screen applies: daily "
               "volume of at least 0.1% of market cap, measured over 30 days."])
S += H2("7.2 Creating an index")
S += numbered(["The creator picks listed tokens and k; the factory sets <i>units = k × supply</i>, copies the vault "
               "addresses and deploys.",
               "The first mint seeds it, and the creator opens the index token's Uniswap pool. That official pool "
               "has a deterministic address fixed at creation, which the snapshot exit's look-through claims use."])
S += [CondPageBreak(40 * mm), KeepTogether([P("7.3 Minting (minters, in batches of about $250k or more)", "h2")]
                                          + diagram_mint())]
S += [P("A minter can source native coins anywhere: typically it deposits USDT on an exchange from Ethereum, buys SOL, "
        "and withdraws native SOL on Solana straight to its own wallet before calling the vault's deposit. The "
        "exchange is the minter's risk, never the index's: the index counts only coins that arrive in its vaults. "
        "The 24-hour lock lets watchers compare every proven deposit with the chains themselves.")]
S += bullets([
    "<b>Voiding is automatic:</b> a shortfall proof, or a second proof of the same vault and height that contradicts "
    "the one the order rests on, fails the order in the same transaction that proves it. No guardian or owner act is "
    "involved, so a forged deposit never becomes a transferable share.",
    "<b>A freeze holds an order until it is re-confirmed:</b> an order touching a chain that froze during its lock "
    "needs a fresh vault-state proof from after the freeze, so an expiring freeze never releases shares by itself."])
S += H2("7.4 How users get in and out")
S += table([["Path", "In", "Out"],
            ["Uniswap", "Swap USDC/USDT for the index token", "Swap back"],
            ["Requests", "Mint request, filled by a minter from stock", "Redeem request, filled by a minter"],
            ["Zap (Ethereum-only indexes)", "One transaction", "One transaction"],
            ["In kind", "Minters only (7.3)", "Anyone (7.5)"]], [0.24, 0.38, 0.38], first_bold=True)
S += [CondPageBreak(40 * mm), KeepTogether([P("7.5 In-kind redemption", "h2")] + diagram_redeem())]
S += H2("7.6 Rebalancing")
S += [P("<b>Price moves need nothing.</b> Units are proportional to supplies, so prices cancel out of the weights and a "
        "market-cap index never has to trade when prices move. Trades happen only when a reference supply changes "
        "(weekly) or the list of tokens changes (a new version).")]
S += [P("<b>Supply updates are weekly</b>, one atomic batch, each supply within 0.5% of the figure in force. That "
        "follows a token whose supply grows up to about 30% a year faster than the index's average; monthly updates "
        "would follow only about 6.7%, leaving tokens that unlock 10–40% a year underweight.")]
S += [P("<b>The auction is anchored to units.</b> For each moving component <i>i</i>, with units <i>u</i> and "
        "reference supply <i>f</i>, the hub computes <i>ρ = u / f</i> and a centred, clamped ratio; a single number "
        "λ then falls through the band those ratios span:")]
S += formula("r<sub>i</sub>  =  clamp( 2ρ<sub>i</sub> / (ρ<sub>min</sub> + ρ<sub>max</sub>),  1 − 0.5%,  1 + 0.5% )",
             "new units  u'<sub>i</sub>  =  λ · u<sub>i</sub> / r<sub>i</sub>, rounded up",
             "value-neutral λ*  =  Σ u<sub>i</sub> p<sub>i</sub>  /  Σ (u<sub>i</sub> / r<sub>i</sub>) p<sub>i</sub>,"
             "  a weighted average of the r<sub>i</sub>, so without knowing any price:",
             "<b>min r  ≤  λ*  ≤  max r</b>")
S += numbered([
    "The owner Safe proposes the week's supplies (timelocked, guardian veto). After 7 days, anyone starts the "
    "rebalance; a band narrower than 0.1% means units already follow supplies, and nothing starts.",
    "After 2 days of notice, λ falls from max r to min r over 24 hours. Components whose ratio is above λ are sold, "
    "those below are bought; kept components do not move.",
    "Ethereum-only indexes settle atomically with v3's callback. For vault tokens, an executor accepts at the current "
    "λ, posts a bond of 0.1% of supply and delivers every bought token first, Ethereum tokens at once and other "
    "chains' tokens within 6 hours.",
    "Once the deliveries are proven, the units update and the sold tokens are released. The bond is held 24 hours "
    "more and burned if a delivery proves forged; a missed window burns it and refunds the deliveries."])
S += table([["Worst case, stated plainly", "Bound"],
            ["Per rebalance, to a lone executor who waits for the floor", "1 − λmin/λmax ≤ <b>0.995%</b>"],
            ["Per day, weekly cadence", "≈ <b>0.14%</b>"],
            ["Per year, if every week's supplies moved the full step apart and no executor ever competed",
             "≈ <b>41%</b> (monthly: ≈ 12%)"],
            ["Units per rebalance", "within 0.990× to 1.010×, plus one raw unit"]], [0.7, 0.3])
S += callout("The band applies to the whole moving value, however small the trade.", "A 0.5% revision of a token "
             "weighing 1% trades about 0.005% of the index, yet a lone executor at the floor can take up to about 0.5%. "
             "Any price-free scalar auction has this property; competition, the guardian's cancel and the keep mask "
             "are the recourse.", "warn")
S += callout("Why units-anchored.", "A full fill makes units exactly proportional to supplies again, so keep-mask "
             "skew and rounding drift heal instead of compounding, and the centred clamp narrows a wide band to "
             "1.005% without ever collapsing it. The first draft's formula, u' = λ·k·s' with the band from old and new "
             "supplies, could let λ* leave the band after a keep mask and overpay the executor.", "ok")
S += H2("7.7 Membership changes and freezes")
S += bullets([
    "<b>Versions:</b> a new top-100 list is a new index (for example, quarterly). A coin enters only at rank 80 or "
    "better and leaves only below 120; under the weight floor it joins at 0.2% and leaves only below 0.1% "
    "(proposed), so tokens near the line do not flip in and out.",
    "<b>In-place migration:</b> burning old-version shares into the new version moves the coins both versions share "
    "inside each vault, by a proven Migrate message, so only the differences trade. The old version stays fully "
    "backed.",
    "<b>Freeze:</b> triggered by the guardian, by a proven Freeze message, or automatically by a proven shortfall or "
    "conflicting proof. The vault stops payouts and deposits; mints involving that chain stop; redemption continues "
    "with that chain skipped. It ends by itself after 14 days, and orders it touched need a fresh proof before they "
    "become claimable. A hostile guardian can only re-freeze (delay, not loss) until the owner replaces it."])

# ---------------------------------------------------------------- 8 accounting
S += H1("8. Accounting and invariants")
S += [P("For Ethereum tokens, v3's invariant is unchanged: real balance ≥ shares × units + claims. For a token "
        "<i>t</i> held in the vault on chain <i>c</i>, with <i>S</i> the supply after the operation:")]
S += formula("settled[c][t]  −  ( burned[c][t] − paid[c][t] )   ≥   S × u<sub>t</sub>")
S += bullets([
    "<b>Checked at every mint</b> against a fresh proof of the vault's balance, so the mirror is re-anchored to proven "
    "state each time and a replayed or duplicated deposit cannot inflate it.",
    "<b>Preserved in between without any proof:</b> a burn lowers the required backing by exactly what it adds to "
    "the burned total, and a vault payout lowers the balance and raises the paid total by the same amount."])
S += [P("A worked example (index #7, each share = 0.001 WBTC + 0.01 BNB + 0.05 SOL):")]
S += table([["Event", "Hub on Ethereum", "BNB vault", "Solana vault", "Shares"],
            ["Start", "WBTC 1.0 · mirror BNB 10, SOL 50", "10", "50", "1,000"],
            ["Mint 100 shares (deposits proven)", "WBTC 1.1 · mirror 11 / 55", "11", "55", "1,100"],
            ["Redeem 200 shares", "WBTC 0.9 · 2 BNB and 10 SOL owed", "11 (2 owed)", "55 (10 owed)", "900"],
            ["Burn proofs delivered", "unchanged", "9", "45", "900"]],
           [0.3, 0.32, 0.12, 0.14, 0.12], first_bold=True)
S += table([["Invariant", "Enforced by"],
            ["A vault pays a message at most once, and never more than its balance for that index", "Vault"],
            ["Every order ends settled or failed exactly once; every deposit counts for exactly one order",
             "Hub and vault"],
            ["Per rolling 24 hours, a vault's outflow per token ≤ 4% of that index's balance", "Vault"],
            ["Per rolling 24 hours, newly claimable shares ≤ 4% of supply (seed mint exempt)", "Hub"],
            ["A rebalance fill leaves holders at least λmin/λmax of the moving value", "Hub"],
            ["No amount in any money path depends on a price", "Code review and tests"],
            ["An index's vault addresses never change", "Factory and hub"]], [0.78, 0.22])

# ---------------------------------------------------------------- 9 security
S += H1("9. Security model")
S += H2("9.1 The bounded-loss standard")
S += table([["Requirement", "Meaning"],
            ["Bounded single failure", "No single failure in anything v4 builds costs more than about 0.5% of an index "
                                       "per day (WBTC excepted)"],
            ["Nobody can move funds", "No key, person or company can move index coins; only code acting on proofs"],
            ["Everything checkable", "Anyone can recompute every balance, unit and payout from public chain data"],
            ["Exit always exists", "Holders can redeem the chains that work; claims on the rest never expire"],
            ["No price where money moves", "No amount in any money path is computed from a price"],
            ["Limits in code", "Every bound is enforced by contracts, not by operators or process"]],
           [0.27, 0.73], first_bold=True)
S += H2("9.2 Every failure and its bound")
S += [P("For the floor list (11.2% of the index in vaults, BNB the largest at 4.4%) with 4% daily limits. The Ethereum "
        "proofs are shared by every chain, so a failure there reaches every vault at once; limits of 5% and 10% would "
        "give 0.56% and 1.1% a day below, which is why both are 4%.")]
S += table([["Failure", "Defense", "Worst case"],
            ["One Ethereum-side proof system broken", "Coins leave a vault only on P1 and P2", "Nothing moves"],
            ["Both Ethereum-side systems broken (double failure)", "Speed limit, watchers, freeze",
             "Every vault at once: 11.2% × 4% ≈ 0.45%/day"],
            ["A chain's deposit proof broken: forged deposit", "A mint needs every token and Tier 1 in real balances; "
             "any honest proof contradicts it; 24h lock; mint cap",
             "In the lock: 0. Undetected (double failure): 4.4% × 4% ≈ 0.18%/day one chain; 0.45%/day all chains"],
            ["A chain's deposit proof broken: forged rebalance delivery", "Band-bounded legs; bond held 24h",
             "≤ 0.11% per rebalance, mostly covered by the 0.1% bond"],
            ["Lone executor at the auction's floor", "Competition; guardian cancel", "0.995% per rebalance; "
                                                                                    "≈ 0.14%/day weekly"],
            ["A vault chain's validators corrupted", "Caps below the lower of the economic and the concentration cap",
             "Unprofitable by construction"],
            ["A vault-chain upgrade breaks the vault program", "Chains that keep programs working; tests against "
                                                                 "release candidates", "That chain frozen: ≤ 4.4%"],
            ["Replay, look-alike contracts, misparsing", "Used-marks, domain separation, exact identities, parsing "
                                                         "inside the proof, formal verification", "Code-level"],
            ["Owner Safe compromised", "Timelocks, guardian veto, fixed vault addresses", "0 immediately; 30 days' "
                                                                                          "public notice"],
            ["Owner and guardian both compromised (double failure)", "A state verifier swapped in 2 days could admit "
             "forged mints; watchers alert holders", "≤ 0.45%/day after 2 days"],
            ["Guardian compromised", "Freeze only, expiring; owner replaces it", "Delay"],
            ["Ethereum upgrade breaks proofs", "Section 10's four layers", "Delay: 37–97 days; 180 at most"],
            ["Provers disappear · a chain halts", "Open-source prover · skip the chain; claims never expire", "Delay"],
            ["Liquidity disappears", "In-kind exit always available", "A discount, not a loss"],
            ["<b>WBTC custodian fails or freezes</b>", "Accepted exception (9.4)", "<b>73.2–82.5%</b>"]],
           [0.27, 0.46, 0.27])
S += H2("9.3 Cost-to-corrupt caps")
S += formula("value held in a chain's vault (all indexes)   ≤   α × cost of corrupting that chain's finality",
             "with α well below one (for example 0.1)")
S += [P("That bound assumes an economic attacker. Where a few known entities can finalize a block alone, coercion or "
        "insider risk is not priced by stake, so each chain also has a <b>validator-concentration cap</b>, set from "
        "the smallest number of entities holding two thirds of its finality weight; a chain's cap is the lower of the "
        "two, and the concentration cap binds for BNB Chain, Tron and HyperEVM. Caps are quantities, so the contracts "
        "need no price; lowering one is a protective message either proof system can carry. Chains without certain "
        "finality stay out: Ethereum Classic, 51%-attacked in 2019 and 2020, is excluded.")]
S += H2("9.4 The Bitcoin exception")
S += table([["Bitcoin weight cap", "Tracking error/yr", "Loss if one custodian fails: WBTC only", "With a WBTC/tBTC "
                                                                                                   "split"],
            ["none (70.7%)", "2.0%", "70.7%", "35.4%"], ["60%", "2.5%", "60%", "30%"],
            ["50%", "4.1%", "50%", "25%"], ["40%", "6.0%", "40%", "20%"]], [0.22, 0.2, 0.33, 0.25])
S += [P("The only way to bring Bitcoin inside the standard is a Bitcoin vault built on a pre-signed transaction tree, "
        "where one honest signer out of n keeps the coins safe. tBTC's supply (4,177 BTC on 29 Sep 2026) limits how "
        "large a split index can grow.")]
S += H2("9.5 Trust assumptions and keys")
S += [P("The complete list of what v4 trusts: Ethereum's consensus (full finality); each vault chain's consensus, "
        "bounded by 9.3; at least one of P1 and P2 being sound for coins in vaults; for mints, each chain's deposit "
        "proof being sound or one watcher being live within 24 hours; the proof systems' setup; WBTC's custodian; token "
        "issuers' own admin powers (labelled in the app); the owner Safe for listings, caps, supplies and rotation; "
        "the guardian for freezes.")]
S += table([["Key", "Holder", "Power"],
            ["Owner", "Safe, 3-of-5 hardware wallets, separate people, no modules", "Timelocked governance, including "
                                                                                    "30-day rotation"],
            ["Owner emergency multisig", "The owner's signers, one multisig per vault chain",
             "Nothing, unless that vault has stalled for 7 days; then only propose a continuity-tested successor"],
            ["Guardian", "Separate signers; one freezer address per vault chain", "Veto, cancel, freeze"],
            ["Deployer", "Hardware wallet or encrypted keystore", "None after deployment"],
            ["Everyone else", "Gas wallets", "None"]], [0.22, 0.38, 0.4], first_bold=True)
S += callout("No custody provider is needed.", "No company holds the index's coins; the only outside custodian is the "
             "one inside WBTC.", "ok")

# ---------------------------------------------------------------- 10 upgrades
S += H1("10. Surviving upgrades")
S += [P("A vault follows Ethereum with fixed verification code. If Ethereum changes a format the code relies on, and "
        "no rotation happened first, the vault can no longer verify burns. No code written in advance can know rules "
        "nobody anticipated, so the design makes whoever supplies new rules powerless in normal times, constrains "
        "them with validator signatures in an emergency, and guarantees coins are never stuck for good.")]
S += diagram_layers()
S += bullets([
    "<b>Prevention.</b> Verifiers understand the current Ethereum version and the next, chosen by the version number "
    "validators sign into every block. New ones are rotated in 90 days before each scheduled upgrade, enough to "
    "absorb a hostile veto, a guardian replacement and a second rotation.",
    "<b>Fail closed.</b> An unknown format is rejected; payouts can stop but never go to the wrong person.",
    "<b>Stall-gated recovery.</b> A vault enters stall mode after 7 days without a new checkpoint. While formats are "
    "unchanged anyone can feed it checkpoints, so nobody can fake a stall. Only then may the owner's emergency "
    "multisig propose a successor, which must pass a <b>continuity test</b>: start from the last checkpoint the old "
    "verifier trusted, show every later checkpoint signed by two thirds of the known validators' stake (with "
    "Ethereum's churn limits), and re-verify past messages. Validator keys do not change with data formats, so a "
    "successor cannot invent blocks. 30 days of public review follow; the guardian may veto at most twice.",
    "<b>Snapshot exit.</b> If nothing is adopted within 180 days, holders at the last verified checkpoint are paid "
    "directly: ordinary wallets sign with their Ethereum key, contracts use a recovery address registered in "
    "advance, and liquidity providers of the official Uniswap pool claim through it, each proving its position at "
    "the checkpoint. From then on the vault refuses every burn issued after the checkpoint, so no coin is paid twice."])
S += callout("What remains open:", "a change of Ethereum's signature scheme itself (a future post-quantum migration) "
             "would remove the continuity test's anchor and must be handled by prevention, years ahead; and the cost of "
             "proving long chains of full-finality checkpoints on each vault chain.", "warn")
S += H2("10.1 Vault chains upgrade too")
S += [P("BNB Chain and Solana upgrade several times a year, and Solana has adopted Alpenglow, a new consensus. The same "
        "prevention applies in the other direction:")]
S += bullets([
    "<b>Fork-aware state verifiers</b> on Ethereum accept each chain's current and next announced formats, chosen by "
    "the version its validators sign.",
    "<b>Rotated ahead through the listing timelock:</b> the next verifier executes 2 days after it is proposed unless "
    "the guardian cancels, well inside any chain's upgrade lead time.",
    "<b>Solana's proof is built for Alpenglow</b> from the start, so its switch is not a rotation.",
    "<b>Fail closed:</b> an unknown format stops only mints, rebalance deliveries and shortfall evidence for that "
    "chain; burns still reach the vault, so no coin is stuck."])
S += callout("A new risk: an upgrade that breaks the vault program itself.", "A vault is immutable, so a runtime "
             "change that stops it running would freeze that chain's coins until the chain restores compatibility: at "
             "most its weight, 4.4% for BNB. Defenses: prefer chains that keep deployed programs working, use only "
             "long-stable features, and run every vault's tests against each chain's release candidates.", "warn")

# ---------------------------------------------------------------- 11 scale
S += H1("11. Scale, liquidity and reliability")
S += H2("11.1 Gas and latency (estimates to confirm with prototypes)")
S += table([["Operation", "Main costs", "Time"],
            ["Mint settlement", "One proof verification per vault chain (~0.3–0.5M gas each) + ~50k per Ethereum "
                                "token", "Inside a 2-hour deadline; claimable 24h later"],
            ["In-kind redemption", "~50k gas per Ethereum token + ~30k per chain's Burn",
             "~15–30 min per chain"],
            ["Create an index", "One clone; ~25k gas per component stored", "One transaction"],
            ["Rebalance", "Deliveries, one combined proof, releases; at 100 tokens an atomic fill fits the 16.8M cap "
                          "only for an executor holding inventory", "2-day notice + ≤ 24h auction + 6h delivery"]],
           [0.2, 0.5, 0.3], first_bold=True)
S += H2("11.2 Liquidity: the real throughput limit")
S += [P("Minters can trade on any venue, but each token still has limited daily volume. Since weight is proportional "
        "to market cap, the index's daily capacity at participation rate <i>p</i> is set by its least-traded token:")]
S += formula("capacity  =  p  ×  basket market cap  ×  min over tokens of ( daily volume / market cap )")
S += table([["Binding token (29 Sep 2026)", "Weight", "24h volume", "Daily limit at 1% of volume"],
            ["LEO", "0.35–0.40%", "$0.5M on an $8.3B cap", "$1.3–1.5M"],
            ["WBTC", "70–81%", "$201M (Bitcoin: $23.8B)", "$2.5–2.8M"],
            ["M", "0.10%", "$1.9M", "$18.8M"],
            ["GT", "0.05–0.06%", "$2.6M", "$42–48M"]], [0.3, 0.17, 0.28, 0.25], first_bold=True)
S += [P("That table holds all 54 tokens. <b>Under the 0.2% floor</b> the thin tail is gone: with LEO screened out, the "
        "least-traded token is BNB (0.70% of its market cap a day), which sets the bound at about <b>$160M a day</b>, "
        "or $2.75M if minters use only WBTC's own volume. The index never sells anything itself, so thin liquidity can "
        "widen the index token's discount but cannot cost holders their coins.")]
S += H2("11.3 Liveness and monitoring")
S += bullets([
    "Proving is permissionless and open source; any holder can prove their own burn.",
    "A halted chain affects only its own leg.",
    "Watchers check every block: vault state against the mirror, payouts against burns, the unit invariants and the "
    "upgrade calendars of Ethereum and every vault chain. Provable problems go on-chain as Shortfall or a "
    "conflicting proof; others alert the guardian.",
    "Launch is guarded: low quantity caps and per-index value limits that rise over months."])

# ---------------------------------------------------------------- 12 valuation
S += H1("12. Valuing the index")
S += [P("Proofs establish quantities, not worth. The value is calculated off-chain, the same way an ETF's is, and "
        "nothing on-chain depends on it:")]
S += formula("value of one share  =  Σ units<sub>i</sub> × price<sub>i</sub>",
             "value of the index  =  value of one share × total shares")
S += table([["Choice", "Method"],
            ["Sources", "Several exchanges and aggregators, and Chainlink where it exists"],
            ["Combining", "The median, dropping any source more than ~2% from the rest"],
            ["Which asset", "Exactly what the index holds: WBTC at WBTC's own price, with Bitcoin's shown beside it as "
                            "a warning light"],
            ["Stale data", "A price older than ~10 minutes marks the value as estimated"],
            ["Timing", "A live value every ~15 seconds; an official value at 00:00 UTC"],
            ["Payouts owed", "Excluded: they belong to people who already redeemed"]], [0.2, 0.8], first_bold=True)

# ---------------------------------------------------------------- 13 tradeoffs
S += H1("13. Trade-offs")
S += table([["Chosen", "Rejected", "Why"],
            ["Ownerless proof vaults", "Bonded operator multisigs", "Operators can sign coins away; bonds and speed "
                                                                     "limits only bound it"],
            ["Hold only what can be held", "A swap tracking the rest", "Tracks rather than holds; oracle-sized "
                                                                       "payments"],
            ["WBTC for Bitcoin (for now)", "THORChain", "~$70M of pools in total, ~$43M of bonded security, Bitcoin "
                                                        "halted when checked, positions half RUNE"],
            ["One vault per chain", "One vault per index", "Fewer deployments and audits; per-index balances keep "
                                                           "indexes separate"],
            ["Balance proofs for the mirror", "Adding up deposit events", "Replayed or missed events cannot drift the "
                                                                          "books"],
            ["Price-free units and λ bounds", "Chainlink or DEX prices", "No manipulation surface; most tokens have no "
                                                                         "feed"],
            ["Minters and requests", "The protocol bridging and swapping", "No bridge, no keeper, no multi-chain price "
                                                                           "risk for users"],
            ["Versions for membership", "Constituent changes by auction", "No price needed; holders choose when to "
                                                                          "move"],
            ["Two proof systems where coins leave, one for deposits", "Two everywhere", "Deposits are contained by "
             "the lock, the mint cap and conflicting-proof evidence; Stage B needs 6 systems, not 10"],
            ["Two Ethereum-side systems", "One", "A single circuit or verifier bug would otherwise be total"],
            ["A 0.2% weight floor", "Every holdable token", "0.6 points of tracking error for 22 → 9 vault chains"],
            ["Weekly supply updates", "Monthly", "Follows supply growth up to 30% a year, not 6.7%"],
            ["Units-anchored λ, centred clamp", "Old and new supply ratios", "Bounded after keep masks; heals "
                                                                               "drift; cannot stall"]],
           [0.27, 0.27, 0.46], first_bold=True)

# ---------------------------------------------------------------- 14 params
S += H1("14. Parameters (initial values, to tune)")
S += table([["Parameter", "Value"],
            ["Maximum tokens per index", "100"], ["Minimum raw units per token", "10,000"],
            ["Mint order deadline", "2 hours (maximum 6)"], ["Lock on newly minted shares", "24 hours"],
            ["Mint cap", "4% of supply per rolling 24 hours"],
            ["Speed limit", "4% of an index's vault balance per token per rolling 24 hours"],
            ["Freeze duration", "14 days"],
            ["Verifier rotation delay · lead before an upgrade", "30 days · 90 days"],
            ["Stall period · recovery review · guardian vetoes", "7 days · 30 days · 2 per stall"],
            ["Snapshot exit", "180 days after a stall began"],
            ["Listing delay · proposal window · guardian-change delay", "2 days · 7 days · 7 days (as v3)"],
            ["Reference supply step", "0.5% per update (factory) and per rebalance (hub clamp)"],
            ["Minimum band", "0.1%"],
            ["Rebalance interval · notice · auction · delivery", "7 days · 2 days · 24 hours · 6 hours"],
            ["Rebalance bond", "0.1% of supply, in index shares; held 24 hours after settlement"],
            ["Weight floor · membership buffer (flagship policy)", "Join at 0.2%, leave below 0.1% (proposed) · "
                                                                  "enter at rank ≤ 80, leave below 120"],
            ["Quantity caps", "Per token, from 9.3; low at launch"],
            ["Liquidity screen (listing policy)", "Daily volume ≥ 0.1% of market cap over 30 days"]], [0.55, 0.45])

# ---------------------------------------------------------------- 15 changes
S += H1("15. Recorded decisions and funding")
S += table([["Recorded decision (AGENTS.md)", "Change in v4"],
            ["Components on Ethereum mainnet only", "Tier 2 coins live in vaults on their own chains"],
            ["Prices from Chainlink USD feeds", "No prices in money paths; units from supplies"],
            ["At most 20 components", "100"],
            ["No pause", "Guardian freeze that expires by itself (owner decision, 29 Sep 2026)"],
            ["No upgrade", "30-day verifier rotation (owner decision, 29 Sep 2026) and stall-gated recovery"],
            ["One-click mint and burn for every index", "Only for Ethereum-only indexes up to ~35 tokens"],
            ["Capped 30/20 methodology", "Retired: it trades on every price move and needs every price"],
            ["Monthly rebalancing", "Weekly supply updates, 7-day interval (owner decision, 30 Sep 2026)"],
            ["The seven-token launch whitelist", "The floor list's Ethereum tokens: WBTC, WETH, LINK, UNI (+ WBT after "
                                                 "its check); native SOL comes with Stage B"],
            ["v3 as the product", "v4 replaces v3, kept at tag v3.0.0 and on Sepolia (owner decision, 30 Sep 2026)"],
            ["No fees", "Under review (15.1)"],
            ["Owner Safe of at least 2 signatures", "3-of-5 hardware wallets, because rotation can reach existing funds "
                                                    "after 30 days"]], [0.42, 0.58], first_bold=True)
S += [P("Kept from v3: in-kind backing, addresses that commit to contents, fixed constituents per index, untrusted "
        "executors behind a reentrancy guard, standard ERC-20s only on Ethereum.")]
S += H2("15.1 Funding: an open decision")
S += [P("Minters earn spreads and executors earn auction discounts, but nobody is paid for two audits per component, "
        "ZK-specialist audits, watchers on every chain, or a bug bounty sized to the largest vault: 4.4% of the index, "
        "<b>$4.4M at $100M</b>. Three price-free models:")]
S += table([["Model", "How", "Revenue at $100M", "Who pays"],
            ["Minter fee", "e.g. 5 bp per in-kind mint and redemption, paid in index shares to a fixed treasury",
             "≈ $100k/yr at two turnovers a year", "Minters, via a ~5 bp wider spread; holders who never mint or "
                                                   "redeem pay nothing directly"],
            ["Management fee", "e.g. 0.10% a year through a unit scale that shrinks over time",
             "≈ $100k/yr", "Every holder, 0.10% a year"],
            ["No fee", "The team or grants fund it", "—", "Outside funders"]], [0.16, 0.38, 0.18, 0.28],
           first_bold=True)
S += [P("In each case the treasury is fixed at creation and can do nothing but receive, so no model gives anyone power "
        "over index coins. <b>This is the owner's decision</b>; until it is made, v4 keeps no fees.")]

# ---------------------------------------------------------------- 16 build
S += H1("16. Build stages and verification")
S += table([["Stage", "Build", "Not needed yet"],
            ["A", "Price-free factory and hub, supply batches, MintRequests, the λ auction (atomic, on Ethereum), "
                  "zap limit; holds WBTC, WETH, LINK, UNI (+ WBT)", "Vaults, proofs, mirror, freeze"],
            ["Prototype", "A full-finality Ethereum proof verified on BNB Chain and on Solana, and a BNB Chain state "
                           "proof verified on Ethereum, with measured cost and latency: decides Stage B", "—"],
            ["B", "One EVM vault for BNB Chain, HyperEVM and Tron; one for Solana; P1/P2 Ethereum verifiers on each; "
                  "one state verifier per chain; mirror, orders, limits, freeze, migration, rotation, recovery, "
                  "snapshot exit, watchers; BNB Chain end to end first", "—"],
            ["C", "Avalanche, NEAR, Stellar, Hedera, Cardano, one at a time, each only if its finality, proof cost, "
                  "cap and value justify it (together +1.3 points of coverage)", "—"]], [0.13, 0.6, 0.27],
           first_bold=True)
S += bullets([
    "Formal proofs of the invariants in section 8 for the hub and every vault.",
    "100% coverage and invariant fuzzing, as v3 already requires.",
    "Differential tests running P1 and P2 on the same real chain data; parser fuzzing against recorded transactions.",
    "Fork tests on every chain, a testnet period, two independent audits per component, and a bug bounty sized to the "
    "largest vault.",
    "Regression tests named after each finding id, as v3's gate 6 requires."])

# ---------------------------------------------------------------- 17 open
S += H1("17. Open questions")
S += bullets([
    "<b>Continuity proofs:</b> the cost of proving long chains of full-finality checkpoints on each vault chain; and a "
    "change of Ethereum's signature scheme, which prevention must handle years ahead.",
    "<b>Bitcoin:</b> add tBTC and a weight cap, then a Bitcoin vault.",
    "<b>Proving costs and times</b> per chain, and whether one combined proof per mint is practical across the 9 "
    "floor chains; the sync-committee fallback's parameters if needed.",
    "<b>Cost to corrupt</b> and validator concentration of each vault chain, to set the quantity caps. <b>Cardano's "
    "finality is probabilistic</b>, which the deterministic-finality rule excludes; its Stage C gate decides. Hedera's "
    "permissioned council gets the same check.",
    "<b>Real supply histories</b> for the backtest, since constant supplies understate tracking error.",
    "<b>WBT's listing check:</b> admin powers, float and Ethereum depth.",
    "<b>Funding</b> (15.1), and <b>a tighter auction</b> whose exposure scales with the trade's size.",
    "<b>Small indexes and the speed limit:</b> a floor so the 4% limit never blocks small redemptions.",
    "<b>On-chain value</b> for lending markets, if wanted: a time-weighted average of the index token's own Uniswap "
    "price, never a posted price.",
    "<b>Issuer tokens</b> (WBT, LEO, OKB, BGB, GT, KCS, WLFI): which can freeze or mint; whether GT, KCS and ARB are "
    "canonical on Ethereum or belong in a vault on their home chain.",
    "<b>Regulation:</b> whether any market served expects a named custodian."])

# ---------------------------------------------------------------- appendix
S += H1("Appendix: data sources")
S += table([["Data", "Source", "Date"],
            ["Top 100, market caps, 24h volumes, Ethereum contract map", "CoinPaprika public API", "29 Sep 2026"],
            ["One-year daily prices for the backtests", "DefiLlama coins API (CoinGecko identifiers)",
             "365 days to 29 Sep 2026"],
            ["Uniswap V3 depth and quotes, token facts, feed answers", "Ethereum mainnet via a public RPC, block "
                                                                       "~26,083,340", "29 Sep 2026"],
            ["Chainlink feeds on Ethereum (heartbeat, deviation)", "Chainlink's public feed directory",
             "29 Sep 2026"],
            ["THORChain chains, pools and bond", "THORNode and Midgard through a public gateway", "29 Sep 2026"],
            ["v3 gas at 20 components", "Mainnet-fork measurements recorded in ARCHITECTURE.md (CR-I08)", "2026"],
            ["Floors, stages and capacity", "design/analysis/floor.py over the saved snapshot", "29 Sep 2026"]],
           [0.42, 0.4, 0.18])
S += [P("Backtests hold today's top-100 membership and current supplies constant over the year, so they understate "
        "tracking error for tokens whose supply grows; they measure tracking, not future returns. Some exchange tokens' reported volumes are "
        "unreliable; re-measure over 30 days before setting the liquidity screen.", "small")]

doc.build(S)
print("wrote", OUT)
