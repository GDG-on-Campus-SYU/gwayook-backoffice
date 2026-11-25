"""Build the two guides from JSON exported by lib/user-guides.ts on stdin.

Requires reportlab, pypdf and the Windows Malgun Gothic fonts.
"""
import json
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

from pypdf import PdfReader
from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, PageBreak, KeepTogether

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs" / "guides"
NAVY = colors.HexColor("#173552")

MUTED = colors.HexColor("#526779")
PALE = colors.HexColor("#eaf6fa")
FONT_DIR = Path("C:/Windows/Fonts")
pdfmetrics.registerFont(TTFont("Guide", str(FONT_DIR / "malgun.ttf")))
pdfmetrics.registerFont(TTFont("GuideBold", str(FONT_DIR / "malgunbd.ttf")))

BODY = ParagraphStyle("body", fontName="Guide", fontSize=10, leading=15.3,
                      textColor=NAVY, wordWrap="CJK", alignment=TA_LEFT, spaceAfter=6)
HEADING = ParagraphStyle("heading", parent=BODY, fontName="GuideBold", fontSize=13,
                         leading=19, spaceBefore=8, spaceAfter=10)
INTRO = ParagraphStyle("intro", parent=BODY, fontSize=10.2, leading=16, textColor=MUTED)
MENU = ParagraphStyle("menu", parent=BODY, fontSize=9, leading=14, textColor=MUTED, spaceAfter=13)


def page_frame(canvas, document, guide):
    width, height = A4
    canvas.saveState()
    canvas.setFillColor(PALE)
    canvas.rect(0, height - 108, width, 108, fill=1, stroke=0)
    canvas.setFillColor(NAVY)
    canvas.setFont("GuideBold", 9)
    canvas.drawString(42, height - 31, "2026 GWAYOOK-THON")
    canvas.setFont("GuideBold", 22)
    canvas.drawString(42, height - 66, guide["title"])
    canvas.setFillColor(MUTED)
    canvas.setFont("Guide", 9)
    canvas.drawString(42, height - 88, "필요한 순간, 필요한 기능을 찾아보세요.")
    canvas.setStrokeColor(colors.HexColor("#dbe5ed"))
    canvas.line(42, 43, width - 42, 43)
    canvas.setFont("Guide", 8)
    canvas.drawString(42, 29, f"개정 {guide['revision']}  |  일정·마감은 앱의 최신 표시를 확인하세요.")
    canvas.drawRightString(width - 42, 29, str(document.page))
    canvas.restoreState()


def build(guide, filename):
    sections = guide["sections"]
    assert len({s["id"] for s in sections}) == len(sections)
    output = OUTPUT / filename
    document = SimpleDocTemplate(str(output), pagesize=A4, rightMargin=42, leftMargin=42,
                                 topMargin=126, bottomMargin=60, title=guide["title"],
                                 author="과육톤 운영팀", subject="과육톤 앱 사용안내",
                                 pageCompression=1)
    story = []
    for index, section in enumerate(sections):
        if index and index % 3 == 0:
            story.append(PageBreak())
        if index == 0:
            story.extend([Paragraph(escape(guide["intro"]), INTRO), Spacer(1, 9)])
        heading = Paragraph(f"{index + 1:02d}  {escape(section['title'])}", HEADING)
        steps = [Paragraph(f"{step_index + 1}. {escape(step)}", BODY)
                 for step_index, step in enumerate(section["steps"])]
        story.append(KeepTogether([heading, steps[0]]))
        story.extend(steps[1:])
        if section.get("linkLabel"):
            story.append(Paragraph(f'앱 메뉴 · {escape(section["linkLabel"])}', MENU))
    document.build(story, onFirstPage=lambda c, d: page_frame(c, d, guide),
                   onLaterPages=lambda c, d: page_frame(c, d, guide))
    reader = PdfReader(output)
    normalized = re.sub(r"\s+", "", "".join(page.extract_text() for page in reader.pages))
    for section in sections:
        for text in [section["title"], *section["steps"]]:
            assert re.sub(r"\s+", "", text) in normalized, f"Missing PDF text: {section['id']}"
    expected_pages = (len(sections) + 2) // 3
    assert len(reader.pages) == expected_pages, f"Expected {expected_pages} pages; got {len(reader.pages)}"
    print(f"{filename}: {len(reader.pages)} pages, {output.stat().st_size} bytes, complete Korean text verified")


guides = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
assert len(guides) == 2
OUTPUT.mkdir(parents=True, exist_ok=True)
build(guides[0], "participant-guide.pdf")
build(guides[1], "staff-guide.pdf")
