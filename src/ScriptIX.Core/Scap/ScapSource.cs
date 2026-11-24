using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;

namespace ScriptIX.Scap;

static class X
{
    /// Children by local name, so XCCDF 1.1/1.2 and every OVAL namespace read the same.
    public static IEnumerable<XElement> Els(this XElement e, string name) => e.Elements().Where(c => c.Name.LocalName == name);
    public static XElement? El(this XElement e, string name) => e.Elements().FirstOrDefault(c => c.Name.LocalName == name);
    public static string At(this XElement e, string name) => (string?)e.Attribute(name) ?? "";
    public static string Text(this XElement? e) => e == null ? "" : Regex.Replace(e.Value, @"\s+", " ").Trim();
    public static bool IsTrue(string s) => s is "true" or "1";
    public static bool IsFalse(string s) => s is "false" or "0";
}

/// <summary>The files inside a SCAP source: a data stream, or single XCCDF / OVAL / CPE files next to each other.</summary>
public sealed class ScapSource
{
    public const long MaxSize = 400L * 1024 * 1024;

    readonly Dictionary<string, XElement> byName = new(StringComparer.Ordinal);   // href or file name -> root element
    readonly Func<string, Stream?>? sibling;
    readonly HashSet<string> tried = new(StringComparer.OrdinalIgnoreCase);

    public XElement? Benchmark { get; private set; }
    public XElement? Root { get; private set; }
    /// <summary>data stream, XCCDF, OVAL, tailoring, results...</summary>
    public string Kind { get; private set; } = "";
    public string Version { get; private set; } = "";
    public List<XElement> OvalFiles { get; } = new();
    public List<XElement> Dictionaries { get; } = new();
    public List<XElement> Ocil { get; } = new();
    public List<string> Benchmarks { get; } = new();

    ScapSource(Func<string, Stream?>? sibling) => this.sibling = sibling;

    public static XDocument ReadXml(Stream s, CancellationToken ct = default)
    {
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, IgnoreComments = true,
            IgnoreProcessingInstructions = true, MaxCharactersFromEntities = 1024, CloseInput = false
        };
        using var r = XmlReader.Create(s, settings);
        var d = XDocument.Load(r, LoadOptions.PreserveWhitespace);
        ct.ThrowIfCancellationRequested();
        return d;
    }

    /// "results", "tailoring" or "" (rules, OVAL...), without loading the file.
    public static string Sniff(Stream s)
    {
        using var r = XmlReader.Create(s, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersFromEntities = 1024 });
        r.MoveToContent();
        switch (r.LocalName)
        {
            case "Tailoring": return "tailoring";
            case "TestResult" or "asset-report-collection" or "oval_results": return "results";
            case "Benchmark": break;
            default: return "";
        }
        if (r.IsEmptyElement) return "";
        r.Read();
        while (!r.EOF && r.NodeType != XmlNodeType.EndElement)
        {
            if (r.NodeType == XmlNodeType.Element && r.LocalName == "TestResult") return "results";
            r.Skip();
        }
        return "";
    }

    /// <param name="sibling">opens a file the benchmark refers to, by its name (may return null)</param>
    /// <param name="benchmarkId">which benchmark to use when the data stream holds several</param>
    public static ScapSource Load(Stream s, Func<string, Stream?>? sibling = null, CancellationToken ct = default, string? benchmarkId = null)
    {
        var src = new ScapSource(sibling);
        var root = ReadXml(s, ct).Root ?? throw new FormatException("The XML file is empty.");
        src.Root = root;
        switch (root.Name.LocalName)
        {
            case "data-stream-collection": src.ReadDataStream(root, benchmarkId); break;
            case "Benchmark": src.Kind = "XCCDF benchmark"; src.Benchmark = root; src.Version = Ns(root, "xccdf/"); break;
            case "oval_definitions": src.Kind = "OVAL definitions"; src.OvalFiles.Add(root); src.Version = OvalVersion(root); break;
            case "Tailoring": src.Kind = "XCCDF tailoring"; break;
            case "TestResult": src.Kind = "XCCDF results"; break;
            case "asset-report-collection": src.Kind = "ARF results"; break;
            case "oval_results": src.Kind = "OVAL results"; break;
            case "oval_system_characteristics": src.Kind = "OVAL system characteristics"; break;
            case "oval_variables": src.Kind = "OVAL variables"; break;
            case "cpe-list": src.Kind = "CPE dictionary"; src.Dictionaries.Add(root); break;
            case "ocil": src.Kind = "OCIL questionnaires"; src.Ocil.Add(root); break;
            case "cvrfdoc": src.Kind = "CVRF advisory"; break;
            default: src.Kind = root.Name.LocalName; break;
        }
        if (src.Benchmark != null && src.Kind == "XCCDF benchmark") src.LoadSiblingDictionary();
        return src;
    }

    static string Ns(XElement e, string marker)
    {
        var n = e.Name.NamespaceName;
        int i = n.IndexOf(marker, StringComparison.Ordinal);
        return i < 0 ? "" : n[(i + marker.Length)..];
    }

    public static string OvalVersion(XElement oval) =>
        oval.El("generator")?.Elements().FirstOrDefault(x => x.Name.LocalName == "schema_version")?.Value.Trim() ?? "";

    void ReadDataStream(XElement root, string? benchmarkId)
    {
        Kind = "SCAP data stream";
        XNamespace xl = "http://www.w3.org/1999/xlink";
        var parts = new Dictionary<string, XElement>(StringComparer.Ordinal);
        foreach (var c in root.Elements().Where(e => e.Name.LocalName is "component" or "extended-component"))
            if (c.Elements().FirstOrDefault() is { } body) parts[c.At("id")] = body;

        foreach (var ds in root.Els("data-stream"))
        {
            if (Version.Length == 0) Version = ds.At("scap-version");
            var refs = ds.Descendants().Where(e => e.Name.LocalName == "component-ref").ToList();
            var body = new Dictionary<string, XElement>(StringComparer.Ordinal);
            foreach (var r in refs)
            {
                var target = ((string?)r.Attribute(xl + "href") ?? "").TrimStart('#');
                if (parts.TryGetValue(target, out var el)) body[r.At("id")] = el;
            }
            foreach (var r in refs)
            {
                foreach (var u in r.Descendants().Where(e => e.Name.LocalName == "uri"))
                    if (body.TryGetValue(u.At("uri").TrimStart('#'), out var el)) byName.TryAdd(u.At("name"), el);
                if (!body.TryGetValue(r.At("id"), out var b)) continue;
                switch (b.Name.LocalName)
                {
                    case "Benchmark":
                        var id = b.At("id");
                        if (!Benchmarks.Contains(id)) Benchmarks.Add(id);
                        if (Benchmark == null || (benchmarkId != null && id == benchmarkId)) Benchmark = b;
                        break;
                    case "oval_definitions": if (!OvalFiles.Contains(b)) OvalFiles.Add(b); break;
                    case "cpe-list": if (!Dictionaries.Contains(b)) Dictionaries.Add(b); break;
                    case "ocil": if (!Ocil.Contains(b)) Ocil.Add(b); break;
                }
            }
        }
        foreach (var (k, v) in parts)   // OVAL components that no data stream lists
            if (v.Name.LocalName == "oval_definitions" && !OvalFiles.Contains(v)) { OvalFiles.Add(v); byName.TryAdd(k, v); }
    }

    /// The document a check or platform refers to, from the data stream or a file in the same folder.
    public XElement? Find(string href)
    {
        href = href.TrimStart('#');
        if (href.Length == 0) return OvalFiles.Count == 1 ? OvalFiles[0] : null;
        if (byName.TryGetValue(href, out var e)) return e;
        if (sibling == null || !tried.Add(href)) return null;
        var name = Path.GetFileName(href.Replace('\\', '/'));   // only ever a file next to the benchmark
        if (name.Length == 0 || name != href) return null;
        try
        {
            using var s = sibling(name);
            if (s == null) return null;
            var root = ReadXml(s).Root;
            if (root == null) return null;
            byName[href] = root;
            if (root.Name.LocalName == "oval_definitions") OvalFiles.Add(root);
            else if (root.Name.LocalName == "cpe-list") Dictionaries.Add(root);
            else if (root.Name.LocalName == "ocil") Ocil.Add(root);
            return root;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or XmlException) { return null; }
    }

    void LoadSiblingDictionary()
    {
        // ssg-x-xccdf.xml comes with ssg-x-cpe-dictionary.xml
        var oval = Benchmark!.Descendants().Where(e => e.Name.LocalName == "check-content-ref").Select(e => e.At("href"))
                             .FirstOrDefault(h => h.EndsWith("-oval.xml", StringComparison.Ordinal));
        if (oval != null) Find(oval.Replace("-oval.xml", "-cpe-dictionary.xml"));
    }

    public IEnumerable<string> MissingFiles() => Benchmark == null
        ? Array.Empty<string>()
        : Benchmark.Descendants().Where(e => e.Name.LocalName == "check-content-ref").Select(e => e.At("href"))
                   .Where(h => h.Length > 0).Distinct().Where(h => Find(h) == null);
}
