using System.Buffers.Binary;
using System.Globalization;
using System.IO.Compression;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ScriptIX;

public sealed record ReportData(IReadOnlyList<ResultRow> Rows, string SourceFile, DateTime Generated, ReportDetails Details)
{
    public ResultSummary Summary { get; } = ResultsParser.Summarize(Rows);
    public string Host { get; } = ResultsParser.Describe(SourceFile).Host;
    public string When { get; } = ResultsParser.Describe(SourceFile).When;
    public string Title => Details.Title.Trim().Length > 0 ? Details.Title.Trim() : $"{AppInfo.Name} run report";
    public string Notes => Details.Notes.Trim().Replace("\r\n", "\n");
    public List<ReportImage> Pictures => Details.Pictures.Where(p => p.Mime != null).ToList();

    /// <summary>Label and value lines shown at the top of every format.</summary>
    public List<(string Label, string Value)> Facts()
    {
        var l = new List<(string, string)>();
        void Add(string k, string v) { if (v.Trim().Length > 0) l.Add((k, v.Trim())); }
        Add("Prepared by", Details.NamesText);
        Add("Organization", Details.Organization);
        Add("Host", Host);
        Add("Run", When);
        Add("Source", Path.GetFileName(SourceFile));
        Add("Generated", $"{Generated.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture)} by {AppInfo.Name} {AppInfo.Version}");
        return l;
    }
}

/// <summary>Writes a run report as Word, Excel, Markdown, text, CSV or JSON. No extra libraries: docx and xlsx are zipped XML.</summary>
public static class ReportExport
{
    static readonly UTF8Encoding Utf8 = new(false);

    // ------------------------------------------------------------------ text
    public static string Text(ReportData d)
    {
        var b = new StringBuilder();
        b.AppendLine(d.Title.ToUpperInvariant()).AppendLine(new string('=', Math.Min(d.Title.Length, 78)));
        foreach (var (k, v) in d.Facts()) b.AppendLine($"{k,-13}: {v}");
        if (d.Notes.Length > 0) b.AppendLine().AppendLine("NOTES").AppendLine(d.Notes.Replace("\n", Environment.NewLine));
        b.AppendLine().Append(ResultsParser.HistoryText(d.Rows)).AppendLine().AppendLine("DETAILS");
        foreach (var r in d.Rows)
        {
            b.AppendLine(new string('-', 78));
            b.AppendLine($"#{r.Seq} [{r.Result}{(r.DetailNote.Length > 0 ? " " + r.DetailNote : "")}] {r.Id}  {r.Title}");
            Block("Command", r.Command); Block("Expected", r.Expected); Block("Exit code", r.Rc); Block("Output", r.Output);
        }
        return b.ToString();

        void Block(string k, string v)
        {
            if (v.Length == 0) return;
            b.AppendLine($"{k,-9}: {v.Replace("\r\n", "\n").Replace("\n", Environment.NewLine + new string(' ', 11))}");
        }
    }

    // ------------------------------------------------------------------ Markdown
    /// <param name="assets">folder name of the pictures, relative to the .md file</param>
    public static string Markdown(ReportData d, string assets)
    {
        var b = new StringBuilder();
        var dir = Uri.EscapeDataString(assets);
        if (d.Details.Logo?.Mime != null) b.Append($"![Logo]({dir}/{LogoFile(d.Details.Logo)})\n\n");
        b.Append($"# {Md(d.Title)}\n\n");
        foreach (var (k, v) in d.Facts()) b.Append($"- **{k}:** {Md(v)}\n");
        var s = d.Summary;
        b.Append("\n| Total | Passed | Failed | Skipped | Pass rate |\n|---:|---:|---:|---:|---:|\n");
        b.Append($"| {s.Total} | {s.Passed} | {s.Failed} | {s.Skipped} | {s.PassRate}% |\n\n");
        if (d.Notes.Length > 0) b.Append($"## Notes\n\n{Md(d.Notes)}\n\n");
        b.Append("## Results\n\n| # | Result | ID | What it checks | Command | Expected | RC | Output |\n|---:|---|---|---|---|---|---:|---|\n");
        foreach (var r in d.Rows)
            b.Append($"| {r.Seq} | {Md(r.Result)}{(r.DetailNote.Length > 0 ? " (" + Md(r.DetailNote) + ")" : "")} | {Md(r.Id)} | {Md(r.Title)} | {Code(r.Command)} | {Code(r.Expected)} | {Md(r.Rc)} | {Code(r.Output)} |\n");
        var pics = d.Pictures;
        if (pics.Count > 0)
        {
            b.Append("\n## Pictures\n");
            for (int i = 0; i < pics.Count; i++)
                b.Append($"\n![{Md(pics[i].Caption.Length > 0 ? pics[i].Caption : "Picture " + (i + 1))}]({dir}/{PictureFile(pics[i], i)})\n")
                 .Append(pics[i].Caption.Trim().Length > 0 ? $"\n*{Md(pics[i].Caption.Trim())}*\n" : "");
        }
        return b.ToString();

        static string Code(string v) => v.Length == 0 ? "" : $"<code>{Md(v)}</code>";
    }

    /// <summary>The pictures a Markdown report points to: file name and bytes.</summary>
    public static List<(string Name, byte[] Data)> MarkdownAssets(ReportData d)
    {
        var l = new List<(string, byte[])>();
        if (d.Details.Logo?.Mime != null) l.Add((LogoFile(d.Details.Logo), d.Details.Logo.Data));
        l.AddRange(d.Pictures.Select((p, i) => (PictureFile(p, i), p.Data)));
        return l;
    }

    static string LogoFile(ReportImage i) => "logo." + Ext(i);
    static string PictureFile(ReportImage p, int i) => $"picture{i + 1}.{Ext(p)}";
    static string Ext(ReportImage i) => i.Mime switch { "image/png" => "png", "image/jpeg" => "jpeg", "image/gif" => "gif", _ => "bmp" };

    /// <summary>Makes text literal in Markdown: server output must not turn into tables, links or HTML.</summary>
    static string Md(string v)
    {
        var b = new StringBuilder();
        foreach (var c in WebUtility.HtmlEncode(Clean(v)).Replace("\r\n", "\n"))
            b.Append(c switch
            {
                '\n' => "<br>",
                '|' or '*' or '_' or '`' or '[' or ']' or '~' or '\\' or '$' => $"&#{(int)c};",
                _ => c.ToString()
            });
        return b.ToString();
    }

    // ------------------------------------------------------------------ CSV / JSON
    /// <summary>Same columns the server script writes, so the file opens in ScriptIX again.</summary>
    public static string CsvText(ReportData d)
    {
        var b = new StringBuilder("schema_version,seq,id,title,severity,time,result,detail,rc,seconds,command,expected,output,mode,os,timeout,shell\r\n");
        foreach (var r in d.Rows)
            b.AppendJoin(',', new[] { "3", r.Seq.ToString(CultureInfo.InvariantCulture), r.Id, r.Title, r.Severity, r.Time, r.Result, r.Detail, r.Rc, r.Seconds,
                r.Command, r.Expected, r.Output, r.Mode, r.Os, r.Timeout.ToString(CultureInfo.InvariantCulture), r.Shell }.Select(Q)).Append("\r\n");
        return b.ToString();

        static string Q(string v)
        {
            if (v.Length > 1 && "=+-@".Contains(v[0])) v = "'" + v;   // never a spreadsheet formula
            return "\"" + v.Replace("\"", "\"\"") + "\"";
        }
    }

    public static string Json(ReportData d) => JsonSerializer.Serialize(new
    {
        title = d.Title, names = d.Details.NamesText, organization = d.Details.Organization, notes = d.Notes,
        host = d.Host, run = d.When, source = Path.GetFileName(d.SourceFile), generated = d.Generated,
        generator = $"{AppInfo.Name} {AppInfo.Version}",
        summary = new { total = d.Summary.Total, passed = d.Summary.Passed, failed = d.Summary.Failed, skipped = d.Summary.Skipped, pass_rate = d.Summary.PassRate },
        results = d.Rows.Select(r => new
        {
            seq = r.Seq, id = r.Id, title = r.Title, severity = r.Severity, time = r.Time, result = r.Result, detail = r.Detail, note = r.Note, rc = r.Rc,
            seconds = r.Seconds, command = r.Command, expected = r.Expected, output = r.Output, mode = r.Mode, os = r.Os, timeout = r.Timeout, shell = r.Shell
        })
    }, new JsonSerializerOptions { WriteIndented = true });

    // ------------------------------------------------------------------ Word
    public static byte[] Docx(ReportData d)
    {
        var media = new List<ReportImage>();
        var b = new StringBuilder();
        if (d.Details.Logo?.Mime != null) b.Append("<w:p>").Append(Drawing(d.Details.Logo, 240, 90, "Logo")).Append("</w:p>");
        b.Append(P(d.Title, "Title"));
        foreach (var (k, v) in d.Facts()) b.Append($"<w:p>{R(k + ": ", bold: true)}{R(v)}</w:p>");

        var s = d.Summary;
        b.Append(P("Summary", "Heading1"));
        int[] sw = { 2000, 2000, 2000, 2000, 2000 };
        b.Append(TableStart(sw)).Append(Row(sw, new[] { "Total", "Passed", "Failed", "Skipped", "Pass rate" }, header: true))
         .Append(Row(sw, new[] { $"{s.Total}", $"{s.Passed}", $"{s.Failed}", $"{s.Skipped}", $"{s.PassRate}%" })).Append("</w:tbl>");
        if (d.Notes.Length > 0)
        {
            b.Append(P("Notes", "Heading1"));
            foreach (var line in d.Notes.Split('\n')) b.Append($"<w:p>{R(line)}</w:p>");
        }

        b.Append(P("Results", "Heading1"));
        int[] w = { 620, 1300, 3600, 4700, 620, 4558 };
        b.Append(TableStart(w)).Append(Row(w, new[] { "#", "Result", "ID / what it checks", "Command", "RC", "Output" }, header: true));
        foreach (var r in d.Rows)
        {
            var fill = r.Result switch { "PASS" => "DCFCE7", "FAIL" => "FEE2E2", _ => "F1F5F9" };
            b.Append("<w:tr><w:trPr><w:cantSplit/></w:trPr>")
             .Append(Cell(w[0], R($"{r.Seq}")))
             .Append(Cell(w[1], R(r.Result, bold: true) + (r.DetailNote.Length > 0 ? "<w:r><w:br/></w:r>" + R(r.DetailNote) : ""), fill))
             .Append(Cell(w[2], R(r.Id, bold: true) + "<w:r><w:br/></w:r>" + R(r.Title)))
             .Append(Cell(w[3], R(r.Command, mono: true) + (r.Expected.Length > 0 ? "<w:r><w:br/></w:r>" + R("expected: ") + R(r.Expected, mono: true) : "")))
             .Append(Cell(w[4], R(r.Rc)))
             .Append(Cell(w[5], R(r.Output, mono: true)))
             .Append("</w:tr>");
        }
        b.Append("</w:tbl>");

        var pics = d.Pictures;
        if (pics.Count > 0)
        {
            b.Append(P("Pictures", "Heading1"));
            foreach (var p in pics)
            {
                b.Append("<w:p><w:pPr><w:keepNext/></w:pPr>").Append(Drawing(p, 620, 420, p.Caption.Length > 0 ? p.Caption : p.Name)).Append("</w:p>");
                if (p.Caption.Trim().Length > 0) b.Append($"<w:p>{R(p.Caption.Trim())}</w:p>");
            }
        }
        b.Append("<w:p/><w:sectPr><w:pgSz w:w=\"16838\" w:h=\"11906\" w:orient=\"landscape\"/><w:pgMar w:top=\"720\" w:right=\"720\" w:bottom=\"720\" w:left=\"720\" w:header=\"360\" w:footer=\"360\" w:gutter=\"0\"/></w:sectPr>");

        var z = new Pack();
        z.Add("[Content_Types].xml", XmlHead + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" + ImageTypes +
            "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>" +
            "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>");
        z.Add("_rels/.rels", Rels(("rId1", RelDoc + "officeDocument", "word/document.xml")));
        var rels = new List<(string, string, string)> { ("rIdS", RelDoc + "styles", "styles.xml") };
        for (int i = 0; i < media.Count; i++)
        {
            rels.Add(($"rIdI{i + 1}", RelDoc + "image", $"media/image{i + 1}.{Ext(media[i])}"));
            z.Add($"word/media/image{i + 1}.{Ext(media[i])}", media[i].Data);
        }
        z.Add("word/_rels/document.xml.rels", Rels(rels.ToArray()));
        z.Add("word/styles.xml", XmlHead + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" +
            "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Segoe UI\" w:hAnsi=\"Segoe UI\" w:cs=\"Segoe UI\"/><w:sz w:val=\"18\"/><w:szCs w:val=\"18\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"40\"/></w:pPr></w:pPrDefault></w:docDefaults>" +
            "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style>" +
            "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"120\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"44\"/></w:rPr></w:style>" +
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"280\" w:after=\"100\"/><w:outlineLvl w:val=\"0\"/></w:pPr><w:rPr><w:b/><w:color w:val=\"4F46E5\"/><w:sz w:val=\"28\"/></w:rPr></w:style></w:styles>");
        z.Add("word/document.xml", XmlHead + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" " +
            "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>" + b + "</w:body></w:document>");
        return z.ToArray();

        string P(string text, string style) => $"<w:p><w:pPr><w:pStyle w:val=\"{style}\"/></w:pPr>{R(text)}</w:p>";

        string R(string text, bool bold = false, bool mono = false)
        {
            var pr = (mono ? "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/>" : "") + (bold ? "<w:b/>" : "") + (mono ? "<w:sz w:val=\"16\"/>" : "");
            var parts = Clean(text).Replace("\r\n", "\n").Split('\n').Select(x => $"<w:t xml:space=\"preserve\">{X(x)}</w:t>");
            return $"<w:r>{(pr.Length > 0 ? $"<w:rPr>{pr}</w:rPr>" : "")}{string.Join("<w:br/>", parts)}</w:r>";
        }

        string TableStart(int[] widths) => $"<w:tbl><w:tblPr><w:tblW w:w=\"{widths.Sum()}\" w:type=\"dxa\"/><w:tblBorders>" +
            string.Concat(new[] { "top", "left", "bottom", "right", "insideH", "insideV" }.Select(e => $"<w:{e} w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"CBD5E1\"/>")) +
            "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:top w:w=\"40\" w:type=\"dxa\"/><w:left w:w=\"90\" w:type=\"dxa\"/><w:bottom w:w=\"40\" w:type=\"dxa\"/><w:right w:w=\"90\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>" + string.Concat(widths.Select(x => $"<w:gridCol w:w=\"{x}\"/>")) + "</w:tblGrid>";

        string Row(int[] widths, string[] cells, bool header = false) =>
            $"<w:tr>{(header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")}" + string.Concat(cells.Select((c, i) => Cell(widths[i], R(c, bold: header), header ? "E0E7FF" : null))) + "</w:tr>";

        string Cell(int width, string runs, string? fill = null) =>
            $"<w:tc><w:tcPr><w:tcW w:w=\"{width}\" w:type=\"dxa\"/>{(fill != null ? $"<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"{fill}\"/>" : "")}</w:tcPr><w:p>{runs}</w:p></w:tc>";

        string Drawing(ReportImage img, int maxW, int maxH, string alt)
        {
            media.Add(img);
            int n = media.Count;
            var (cx, cy) = Emu(img, maxW, maxH);
            return $"<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"{cx}\" cy=\"{cy}\"/><wp:docPr id=\"{n}\" name=\"Picture {n}\" descr=\"{X(alt)}\"/>" +
                "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>" +
                $"<pic:nvPicPr><pic:cNvPr id=\"{n}\" name=\"Picture {n}\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"rIdI{n}\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>" +
                $"<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"{cx}\" cy=\"{cy}\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>";
        }
    }

    // ------------------------------------------------------------------ Excel
    public static byte[] Xlsx(ReportData d)
    {
        const int Norm = 0, Head = 1, Pass = 2, Fail = 3, Skip = 4, Title = 5, Bold = 6, Mono = 7;
        var z = new Pack();
        var sheets = new List<string> { "Summary", "Results" };
        var pics = d.Pictures;
        if (pics.Count > 0) sheets.Add("Pictures");
        var logo = d.Details.Logo?.Mime != null ? d.Details.Logo : null;

        // Summary: the logo sits beside the facts
        var b = new StringBuilder();
        int row = 1;
        void Line(params (string Text, int Style)[] cells)
        {
            b.Append($"<row r=\"{row}\">");
            for (int i = 0; i < cells.Length; i++) b.Append(S(Ref(i, row), cells[i].Text, cells[i].Style));
            b.Append("</row>"); row++;
        }
        void Num(string label, string value) { b.Append($"<row r=\"{row}\">{S("A" + row, label, Bold)}<c r=\"B{row}\" s=\"{Norm}\"><v>{value}</v></c></row>"); row++; }
        Line((d.Title, Title));
        foreach (var (k, v) in d.Facts()) Line((k, Bold), (v, Norm));
        row++;
        Num("Total", I(d.Summary.Total)); Num("Passed", I(d.Summary.Passed)); Num("Failed", I(d.Summary.Failed)); Num("Skipped", I(d.Summary.Skipped));
        Line(("Pass rate", Bold), ($"{d.Summary.PassRate}%", Norm));
        if (d.Notes.Length > 0) { row++; Line(("Notes", Bold), (d.Notes, Norm)); }
        z.Add("xl/worksheets/sheet1.xml", Sheet("<cols><col min=\"1\" max=\"1\" width=\"18\" customWidth=\"1\"/><col min=\"2\" max=\"2\" width=\"70\" customWidth=\"1\"/></cols>", b.ToString(), "", logo != null));

        // Results
        b.Clear();
        row = 1;
        Line(new[] { "#", "Result", "Detail", "ID", "What it checks", "Severity", "Command", "Expected", "RC", "Seconds", "Output", "Time" }.Select(h => (h, Head)).ToArray());
        foreach (var r in d.Rows)
        {
            b.Append($"<row r=\"{row}\"><c r=\"A{row}\" s=\"{Norm}\"><v>{I(r.Seq)}</v></c>");
            var cells = new (string, int)[]
            {
                (r.Result, r.Result == "PASS" ? Pass : r.Result == "FAIL" ? Fail : Skip), (r.DetailNote, Norm), (r.Id, Norm), (r.Title, Norm), (r.Severity, Norm),
                (r.Command, Mono), (r.Expected, Mono), (r.Rc, Norm), (r.Seconds, Norm), (r.Output, Mono), (r.Time, Norm)
            };
            for (int i = 0; i < cells.Length; i++) b.Append(S(Ref(i + 1, row), cells[i].Item1, cells[i].Item2));
            b.Append("</row>"); row++;
        }
        double[] widths = { 6, 11, 16, 16, 42, 11, 50, 26, 7, 9, 60, 11 };
        z.Add("xl/worksheets/sheet2.xml", Sheet(
            "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><cols>" +
            string.Concat(widths.Select((w, i) => $"<col min=\"{i + 1}\" max=\"{i + 1}\" width=\"{w.ToString(CultureInfo.InvariantCulture)}\" customWidth=\"1\"/>")) + "</cols>",
            b.ToString(), $"<autoFilter ref=\"A1:L{Math.Max(1, row - 1)}\"/>", false));

        var media = new List<ReportImage>();
        if (logo != null) AddDrawing(1, new[] { (logo, 3, 0, 260, 90) });
        if (pics.Count > 0)
        {
            b.Clear();
            row = 1;
            var anchors = new List<(ReportImage, int, int, int, int)>();
            foreach (var p in pics)
            {
                Line((p.Caption.Trim().Length > 0 ? p.Caption.Trim() : p.Name, Bold));
                anchors.Add((p, 0, row - 1, 640, 420));
                row += (int)(Emu(p, 640, 420).Cy / 9525 / 20) + 3;   // default rows are 20 px high
            }
            z.Add("xl/worksheets/sheet3.xml", Sheet("<cols><col min=\"1\" max=\"1\" width=\"100\" customWidth=\"1\"/></cols>", b.ToString(), "", true));
            AddDrawing(3, anchors.ToArray());
        }

        z.Add("[Content_Types].xml", XmlHead + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" + ImageTypes +
            "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" +
            "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>" +
            string.Concat(sheets.Select((_, i) => $"<Override PartName=\"/xl/worksheets/sheet{i + 1}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>")) +
            (logo != null ? "<Override PartName=\"/xl/drawings/drawing1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>" : "") +
            (pics.Count > 0 ? "<Override PartName=\"/xl/drawings/drawing3.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>" : "") + "</Types>");
        z.Add("_rels/.rels", Rels(("rId1", RelDoc + "officeDocument", "xl/workbook.xml")));
        z.Add("xl/workbook.xml", XmlHead + "<workbook xmlns=\"" + Main + "\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>" +
            string.Concat(sheets.Select((n, i) => $"<sheet name=\"{n}\" sheetId=\"{i + 1}\" r:id=\"rId{i + 1}\"/>")) + "</sheets></workbook>");
        z.Add("xl/_rels/workbook.xml.rels", Rels(sheets.Select((_, i) => ($"rId{i + 1}", RelDoc + "worksheet", $"worksheets/sheet{i + 1}.xml")).Append(("rIdS", RelDoc + "styles", "styles.xml")).ToArray()));
        const string Wrap = "<alignment horizontal=\"left\" vertical=\"top\" wrapText=\"1\" readingOrder=\"1\"/>";   // LTR: mixed Arabic/Latin names keep their order
        string Xf(int font, int fill, string align = Wrap) => $"<xf numFmtId=\"0\" fontId=\"{font}\" fillId=\"{fill}\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\" applyAlignment=\"1\">{align}</xf>";
        string Fill(string c) => $"<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF{c}\"/><bgColor indexed=\"64\"/></patternFill></fill>";
        z.Add("xl/styles.xml", XmlHead + "<styleSheet xmlns=\"" + Main + "\"><fonts count=\"5\"><font><sz val=\"10\"/><name val=\"Segoe UI\"/></font><font><b/><sz val=\"10\"/><color rgb=\"FFFFFFFF\"/><name val=\"Segoe UI\"/></font>" +
            "<font><b/><sz val=\"10\"/><name val=\"Segoe UI\"/></font><font><b/><sz val=\"18\"/><name val=\"Segoe UI\"/></font><font><sz val=\"9\"/><name val=\"Consolas\"/></font></fonts>" +
            "<fills count=\"6\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>" + Fill("4F46E5") + Fill("DCFCE7") + Fill("FEE2E2") + Fill("F1F5F9") + "</fills>" +
            "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" +
            "<cellXfs count=\"8\">" + Xf(0, 0) + Xf(1, 2) + Xf(2, 3) + Xf(2, 4) + Xf(2, 5) + Xf(3, 0, "<alignment vertical=\"top\"/>") + Xf(2, 0) + Xf(4, 0) + "</cellXfs>" +
            "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>");
        return z.ToArray();

        static string I(int n) => n.ToString(CultureInfo.InvariantCulture);
        static string Ref(int col, int r) => $"{(char)('A' + col)}{r}";

        static string S(string cell, string text, int style)
        {
            var t = Clean(text).Replace("\r\n", "\n");
            if (t.Length > 32000) t = t[..32000] + "...";   // Excel's limit is 32,767 per cell
            t = Regex.Replace(Clean(t), "_(?=x[0-9A-Fa-f]{4}_)", "_x005F_");   // Excel would decode _x0041_ as a character
            return t.Length == 0 ? $"<c r=\"{cell}\" s=\"{style}\"/>" : $"<c r=\"{cell}\" s=\"{style}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">{X(t)}</t></is></c>";
        }

        static string Sheet(string before, string rows, string after, bool drawing) =>
            XmlHead + "<worksheet xmlns=\"" + Main + "\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">" + before + "<sheetData>" + rows + "</sheetData>" + after +
            "<pageMargins left=\"0.4\" right=\"0.4\" top=\"0.5\" bottom=\"0.5\" header=\"0.3\" footer=\"0.3\"/><pageSetup orientation=\"landscape\"/>" + (drawing ? "<drawing r:id=\"rId1\"/>" : "") + "</worksheet>";

        void AddDrawing(int sheet, (ReportImage Img, int Col, int Row, int MaxW, int MaxH)[] items)
        {
            var x = new StringBuilder(XmlHead + "<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">");
            var rels = new List<(string, string, string)>();
            for (int i = 0; i < items.Length; i++)
            {
                var it = items[i];
                media.Add(it.Img);
                var file = $"image{media.Count}.{Ext(it.Img)}";
                z.Add("xl/media/" + file, it.Img.Data);
                rels.Add(($"rId{i + 1}", RelDoc + "image", "../media/" + file));
                var (cx, cy) = Emu(it.Img, it.MaxW, it.MaxH);
                x.Append($"<xdr:oneCellAnchor><xdr:from><xdr:col>{it.Col}</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>{it.Row}</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from><xdr:ext cx=\"{cx}\" cy=\"{cy}\"/>" +
                    $"<xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"{i + 2}\" name=\"Picture {i + 1}\"/><xdr:cNvPicPr/></xdr:nvPicPr><xdr:blipFill><a:blip r:embed=\"rId{i + 1}\"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>" +
                    $"<xdr:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"{cx}\" cy=\"{cy}\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>");
            }
            z.Add($"xl/drawings/drawing{sheet}.xml", x.Append("</xdr:wsDr>").ToString());
            z.Add($"xl/drawings/_rels/drawing{sheet}.xml.rels", Rels(rels.ToArray()));
            z.Add($"xl/worksheets/_rels/sheet{sheet}.xml.rels", Rels(("rId1", RelDoc + "drawing", $"../drawings/drawing{sheet}.xml")));
        }
    }

    // ------------------------------------------------------------------ shared
    const string XmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";
    const string Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    const string RelDoc = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/";
    const string ImageTypes = "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
        "<Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/><Default Extension=\"gif\" ContentType=\"image/gif\"/><Default Extension=\"bmp\" ContentType=\"image/bmp\"/>";

    static string Rels(params (string Id, string Type, string Target)[] r) => XmlHead + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
        string.Concat(r.Select(x => $"<Relationship Id=\"{x.Id}\" Type=\"{x.Type}\" Target=\"{x.Target}\"/>")) + "</Relationships>";

    /// <summary>Drops what XML 1.0 forbids (control characters, half surrogates): server output can hold anything.</summary>
    static string Clean(string s)
    {
        var b = new StringBuilder(s.Length);
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (char.IsHighSurrogate(c) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1])) { b.Append(c).Append(s[++i]); continue; }
            b.Append(char.IsSurrogate(c) || c is '￾' or '￿' || (c < 32 && c is not ('\n' or '\r' or '\t')) ? '�' : c);
        }
        return b.ToString();
    }

    static string X(string s) => Clean(s).Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    /// <summary>Size in EMU (9525 per pixel), shrunk to fit, never enlarged.</summary>
    static (long Cx, long Cy) Emu(ReportImage img, int maxW, int maxH)
    {
        var (w, h) = PixelSize(img.Data);
        var k = Math.Min(1.0, Math.Min((double)maxW / w, (double)maxH / h));
        return (Math.Max(1, (long)(w * k)) * 9525, Math.Max(1, (long)(h * k)) * 9525);
    }

    public static (int W, int H) PixelSize(byte[] d)
    {
        try
        {
            int w = 0, h = 0;
            switch (ReportImage.Sniff(d))
            {
                case "image/png": w = BinaryPrimitives.ReadInt32BigEndian(d.AsSpan(16)); h = BinaryPrimitives.ReadInt32BigEndian(d.AsSpan(20)); break;
                case "image/gif": w = BinaryPrimitives.ReadUInt16LittleEndian(d.AsSpan(6)); h = BinaryPrimitives.ReadUInt16LittleEndian(d.AsSpan(8)); break;
                case "image/bmp": w = BinaryPrimitives.ReadInt32LittleEndian(d.AsSpan(18)); h = Math.Abs(BinaryPrimitives.ReadInt32LittleEndian(d.AsSpan(22))); break;
                case "image/jpeg":
                    for (int i = 2; i + 9 < d.Length && d[i] == 0xFF;)
                    {
                        if (d[i + 1] == 0xFF) { i++; continue; }
                        if (d[i + 1] is >= 0xC0 and <= 0xCF and not (0xC4 or 0xC8 or 0xCC))
                        {
                            h = BinaryPrimitives.ReadUInt16BigEndian(d.AsSpan(i + 5)); w = BinaryPrimitives.ReadUInt16BigEndian(d.AsSpan(i + 7));
                            break;
                        }
                        i += 2 + BinaryPrimitives.ReadUInt16BigEndian(d.AsSpan(i + 2));
                    }
                    break;
            }
            if (w > 0 && h > 0) return (w, h);
        }
        catch (ArgumentOutOfRangeException) { }
        return (320, 200);
    }

    sealed class Pack
    {
        readonly MemoryStream ms = new();
        readonly ZipArchive zip;
        public Pack() => zip = new ZipArchive(ms, ZipArchiveMode.Create, true);
        public void Add(string name, string text) => Add(name, Utf8.GetBytes(text));
        public void Add(string name, byte[] data)
        {
            using var s = zip.CreateEntry(name, CompressionLevel.Optimal).Open();
            s.Write(data);
        }
        public byte[] ToArray() { zip.Dispose(); return ms.ToArray(); }
    }
}
