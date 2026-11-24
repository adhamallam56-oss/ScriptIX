using System.Text;
using System.Xml.Linq;
using ScriptIX.Scap;

namespace ScriptIX;

public sealed record ProfileOp(string Kind, string Id, string Value, string Extra = "", string Weight = "");

public sealed class XccdfProfile
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    public string Description { get; init; } = "";
    public string Extends { get; init; } = "";
    public bool Tailored { get; init; }
    /// <summary>The profile's own changes, in file order: select, set-value, refine-value, refine-rule.</summary>
    public List<ProfileOp> Ops { get; } = new();

    // resolved (own changes on top of the profile it extends)
    public HashSet<string> Selected { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, string> Refine { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, string> SetValues { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, ProfileOp> RefineRules { get; } = new(StringComparer.Ordinal);
    public override string ToString() => $"{(Tailored ? "★ " : "")}{Title}  ({Selected.Count} rules)";
}

public sealed class XccdfValue
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    public string Description { get; init; } = "";
    public string Type { get; init; } = "string";
    public string Operator { get; init; } = "equals";
    public string? Default { get; set; }
    public Dictionary<string, string> BySelector { get; } = new(StringComparer.Ordinal);
    /// <summary>complex-value lists, by selector ("" = default)</summary>
    public Dictionary<string, List<string>> Lists { get; } = new(StringComparer.Ordinal);
}

public sealed record SubRef(string ValueId);

public sealed record XccdfFix(string System, string Complexity, string Disruption, string Reboot, List<object> Parts);

public sealed class XccdfGroup
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    public string Description { get; init; } = "";
    public bool DefaultSelected { get; init; } = true;
    public double Weight { get; init; } = 1;
    public XccdfGroup? Parent { get; init; }
    public List<string> Platforms { get; } = new();
    public List<string> Clusters { get; } = new();
}

public sealed class XccdfRule
{
    public string Id { get; init; } = "";
    public string ShortId { get; init; } = "";
    public string Title { get; init; } = "";
    public string Severity { get; init; } = "";
    public string Role { get; init; } = "";
    public string Description { get; init; } = "";
    public string Rationale { get; init; } = "";
    public bool DefaultSelected { get; init; } = true;
    public double Weight { get; init; } = 1;
    public XccdfGroup? Parent { get; init; }
    public List<string> Platforms { get; } = new();
    public List<string> Clusters { get; } = new();
    public List<XccdfFix> Fixes { get; } = new();
    public List<(string System, string Id)> Idents { get; } = new();
    public List<string> References { get; } = new();
    /// <summary>each entry: one of these ids must be selected</summary>
    public List<string[]> Requires { get; } = new();
    public List<string> Conflicts { get; } = new();
    public List<XElement> Checks { get; } = new();

    public IEnumerable<XccdfGroup> Ancestors()
    {
        for (var g = Parent; g != null; g = g.Parent) yield return g;
    }
}

/// <summary>A parsed XCCDF benchmark (alone or inside a SCAP data stream), or rules another importer built.</summary>
public sealed class XccdfDocument
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string Description { get; set; } = "";
    public string Version { get; set; } = "";
    public string Status { get; set; } = "";
    public string FileName { get; set; } = "";
    public ScapSource? Source { get; set; }
    public OvalLibrary? Oval { get; set; }
    public List<XccdfRule> Rules { get; } = new();
    public List<XccdfGroup> Groups { get; } = new();
    public List<XccdfProfile> Profiles { get; } = new();
    public List<string> Platforms { get; } = new();
    public Dictionary<string, XccdfValue> Values { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, string> PlainTexts { get; } = new(StringComparer.Ordinal);
    /// <summary>Values the user changed on top of the profile.</summary>
    public Dictionary<string, string> Overrides { get; } = new(StringComparer.Ordinal);
    public OsTarget Target { get; set; } = OsTarget.Any;

    /// <summary>Rules already built by another importer (CIS PDF, OVAL file): profiles only tick them.</summary>
    public List<RuleItem>? Prebuilt { get; set; }

    readonly Dictionary<string, PlatformNode?> platformCache = new(StringComparer.Ordinal);
    public SortedSet<string> UnknownPlatforms { get; } = new(StringComparer.Ordinal);

    // ---------------------------------------------------------------- profiles
    public void ResolveProfiles()
    {
        foreach (var p in Profiles) Resolve(p);
    }

    public void Resolve(XccdfProfile p)
    {
        var chain = new List<XccdfProfile>();
        for (var x = p; x != null && !chain.Contains(x);)
        {
            chain.Insert(0, x);
            var baseId = x.Extends.TrimStart('#');
            x = baseId.Length == 0 ? null : Profiles.FirstOrDefault(q => q.Id == baseId && q != x && !chain.Contains(q));
        }
        var state = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var g in Groups) state[g.Id] = g.DefaultSelected;
        foreach (var r in Rules) state[r.Id] = r.DefaultSelected;
        p.Selected.Clear(); p.Refine.Clear(); p.SetValues.Clear(); p.RefineRules.Clear();
        foreach (var o in chain.SelectMany(c => c.Ops))
            switch (o.Kind)
            {
                case "select":
                    bool on = X.IsTrue(o.Value);
                    if (state.ContainsKey(o.Id)) state[o.Id] = on;
                    else
                    {
                        foreach (var r in Rules.Where(r => r.Clusters.Contains(o.Id))) state[r.Id] = on;
                        foreach (var g in Groups.Where(g => g.Clusters.Contains(o.Id))) state[g.Id] = on;
                    }
                    break;
                case "set-value": p.SetValues[o.Id] = o.Value; break;
                case "refine-value": p.Refine[o.Id] = o.Value; p.SetValues.Remove(o.Id); break;
                case "refine-rule": p.RefineRules[o.Id] = o; break;
            }
        foreach (var r in Rules)
            if (state[r.Id] && r.Ancestors().All(g => state[g.Id])) p.Selected.Add(r.Id);
        var groups = Groups.Select(g => g.Id).ToHashSet(StringComparer.Ordinal);
        bool On(string id) => p.Selected.Contains(id) || (groups.Contains(id) && state[id]);
        var drop = Rules.Where(r => p.Selected.Contains(r.Id) && (r.Requires.Any(any => !any.Any(On)) || r.Conflicts.Any(On))).ToList();
        foreach (var r in drop) p.Selected.Remove(r.Id);
    }

    public HashSet<string> DefaultSelection()
    {
        var p = new XccdfProfile();
        Resolve(p);
        return p.Selected;
    }

    // ---------------------------------------------------------------- values
    public string? ProfileValue(string id, XccdfProfile? profile)
    {
        if (profile != null && profile.SetValues.TryGetValue(id, out var set)) return set;
        if (!Values.TryGetValue(id, out var v)) return PlainTexts.TryGetValue(id, out var t) ? t : null;
        if (profile != null && profile.Refine.TryGetValue(id, out var sel) && v.BySelector.TryGetValue(sel, out var sv)) return sv;
        return v.Default ?? (v.BySelector.Count > 0 ? v.BySelector.Values.First() : null);
    }

    public string? Value(string id, XccdfProfile? profile) =>
        Overrides.TryGetValue(id, out var o) ? o : ProfileValue(id, profile);

    IReadOnlyList<string> ValueList(string id, XccdfProfile? profile)
    {
        if (!Overrides.ContainsKey(id) && Values.TryGetValue(id, out var v) && v.Lists.Count > 0)
        {
            var sel = profile != null && profile.Refine.TryGetValue(id, out var s) ? s : "";
            if (v.Lists.TryGetValue(sel, out var l) || v.Lists.TryGetValue("", out l)) return l;
        }
        var one = Value(id, profile);
        return one == null ? Array.Empty<string>() : new[] { one };
    }

    /// Values the ticked or selected rules really use.
    public IEnumerable<XccdfValue> UsedValues(IReadOnlySet<string> ruleIds)
    {
        var used = new HashSet<string>(StringComparer.Ordinal);
        foreach (var r in Rules.Where(r => ruleIds.Contains(r.Id)))
        {
            foreach (var f in r.Fixes) foreach (var p in f.Parts.OfType<SubRef>()) used.Add(p.ValueId);
            foreach (var c in r.Checks) foreach (var e in c.DescendantsAndSelf().Where(x => x.Name.LocalName == "check-export")) used.Add(e.At("value-id"));
        }
        return Values.Values.Where(v => used.Contains(v.Id));
    }

    // ---------------------------------------------------------------- rules
    /// Builds rules for a profile (null = no profile: nothing is ticked).
    public List<RuleItem> ToRules(XccdfProfile? profile, CancellationToken ct = default)
    {
        if (Prebuilt != null)
            return Prebuilt.Select(p =>
            {
                var r = p.Clone();
                r.InProfile = profile == null || profile.Selected.Contains(p.Id);
                r.Selected = profile != null && r.InProfile && r.Status == RuleStatus.Ready;
                return r;
            }).ToList();

        var selection = profile?.Selected ?? DefaultSelection();
        var shorts = Rules.GroupBy(r => r.ShortId).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet(StringComparer.Ordinal);
        var list = new List<RuleItem>(Rules.Count);
        foreach (var x in Rules)
        {
            ct.ThrowIfCancellationRequested();
            var refine = profile != null && profile.RefineRules.TryGetValue(x.Id, out var rr) ? rr : null;
            var fix = x.Fixes.FirstOrDefault(f => FixKind(f.System) == "bash");
            var r = new RuleItem
            {
                Id = shorts.Contains(x.ShortId) ? x.Id : x.ShortId,
                FullId = x.Id,
                Title = x.Title,
                Severity = RuleImporter.ParseSeverity(refine is { Value.Length: > 0 } ? refine.Value : x.Severity),
                Target = Target,
                Remediation = fix == null ? "" : FixText(fix, profile),
                Shell = Target == OsTarget.AIX ? "sh" : "bash",
                Notes = x.Description,
                InProfile = selection.Contains(x.Id)
            };
            BuildCheck(r, x, profile, refine?.Extra ?? "");
            r.Selected = profile != null && r.InProfile && r.Status == RuleStatus.Ready;
            list.Add(r);
        }
        return list;
    }

    public static string FixKind(string system) => system switch
    {
        _ when system.Contains("script:ansible", StringComparison.OrdinalIgnoreCase) => "ansible",
        _ when system.Contains("script:puppet", StringComparison.OrdinalIgnoreCase) => "puppet",
        _ when system.Contains("kickstart", StringComparison.OrdinalIgnoreCase) => "kickstart",
        _ when system.Contains("kubernetes", StringComparison.OrdinalIgnoreCase) => "kubernetes",
        _ when system.Contains("ignition", StringComparison.OrdinalIgnoreCase) => "ignition",
        _ when system.Contains("blueprint", StringComparison.OrdinalIgnoreCase) => "blueprint",
        _ when system.Contains("bootc", StringComparison.OrdinalIgnoreCase) => "bootc",
        _ when system.Contains("powershell", StringComparison.OrdinalIgnoreCase) => "powershell",
        _ when system.Contains("script:sh", StringComparison.OrdinalIgnoreCase) || system.Contains("bash", StringComparison.OrdinalIgnoreCase)
            || system.Contains("system:commands", StringComparison.OrdinalIgnoreCase) || system.Length == 0 => "bash",
        _ => "other"
    };

    public string FixText(XccdfFix fix, XccdfProfile? profile)
    {
        var sb = new StringBuilder();
        foreach (var p in fix.Parts)
        {
            if (p is string s) { sb.Append(s); continue; }
            var id = ((SubRef)p).ValueId;
            sb.Append(Value(id, profile) ?? $"<SET {XccdfImporter.Short(id, "_value_")}>");
        }
        return sb.ToString().Trim();
    }

    public string FillIn(XElement e, XccdfProfile? profile)
    {
        var sb = new StringBuilder();
        foreach (var n in e.DescendantNodes())
        {
            if (n is XText t && t.Parent?.Name.LocalName != "sub") sb.Append(t.Value);
            else if (n is XElement { Name.LocalName: "sub" } s) sb.Append(Value(s.At("idref"), profile) ?? "");
        }
        return System.Text.RegularExpressions.Regex.Replace(sb.ToString(), @"\s+", " ").Trim();
    }

    // ---------------------------------------------------------------- checks
    const string OvalSystem = "http://oval.mitre.org/XMLSchema/oval-definitions-5";
    const string SceSystem = "http://open-scap.org/page/SCE";

    void BuildCheck(RuleItem r, XccdfRule x, XccdfProfile? profile, string selector)
    {
        var plat = PlatformFor(x);
        var externals = new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal);
        CheckNode? node = null;

        var complex = x.Checks.FirstOrDefault(c => c.Name.LocalName == "complex-check");
        if (complex != null) node = ComplexNode(complex, profile, externals);
        var simple = x.Checks.Where(c => c.Name.LocalName == "check").ToList();
        if (node == null)
        {
            var oval = simple.Where(c => c.At("system") == OvalSystem).ToList();
            var pick = oval.FirstOrDefault(c => c.At("selector") == selector) ?? oval.FirstOrDefault(c => c.At("selector").Length == 0);
            if (pick != null) node = OvalNode(pick, profile, externals);
        }
        if (node != null && Oval != null)
        {
            var (ir, unsupported) = OvalCompiler.Compile(Oval, node, plat, externals);
            r.Oval = ir;
            r.Command = "oval " + (FirstDefinition(node) ?? x.ShortId);
            r.Mode = CompareMode.Oval;
            r.CheckGap = unsupported.Count == 0 ? "" : string.Join(", ", unsupported);
            return;
        }
        var sce = simple.FirstOrDefault(c => c.At("system") == SceSystem);
        if (sce != null && SceScript(sce, profile) is { } script)
        {
            r.Command = script;
            r.Mode = CompareMode.Sce;
            r.CheckShell = script.Contains("bash", StringComparison.Ordinal) ? "bash" : "sh";
            return;
        }
        r.ManualCheck = Question(simple) ?? "Check this rule by hand.";
        if (plat != null && Oval != null) r.Oval = OvalCompiler.Compile(Oval, null, plat, externals).Ir;
    }

    static string? FirstDefinition(CheckNode n) => n.Definition ?? n.Children.Select(FirstDefinition).FirstOrDefault(d => d != null);

    CheckNode? OvalNode(XElement check, XccdfProfile? profile, Dictionary<string, IReadOnlyList<string>> externals)
    {
        foreach (var e in check.Els("check-export")) externals[e.At("export-name")] = ValueList(e.At("value-id"), profile);
        foreach (var c in check.Els("check-content-ref"))
        {
            var file = Source?.Find(c.At("href"));
            var name = c.At("name");
            if (name.Length > 0)
            {
                if (Oval?.Get(name) != null) return new CheckNode { Definition = name };
                if (file != null) { RefreshOval(); if (Oval?.Get(name) != null) return new CheckNode { Definition = name }; }
                continue;
            }
            if (file?.Name.LocalName != "oval_definitions") continue;
            RefreshOval();
            var defs = file.Els("definitions").Elements().Select(d => d.At("id")).Where(i => i.Length > 0).ToList();
            if (defs.Count == 0) continue;
            return new CheckNode { Operator = "AND", Children = defs.Select(d => new CheckNode { Definition = d }).ToList() };
        }
        return null;
    }

    int ovalFiles = -1;
    void RefreshOval()
    {
        if (Source == null || ovalFiles == Source.OvalFiles.Count) return;
        ovalFiles = Source.OvalFiles.Count;
        Oval = new OvalLibrary(Source.OvalFiles);
    }

    CheckNode? ComplexNode(XElement e, XccdfProfile? profile, Dictionary<string, IReadOnlyList<string>> externals)
    {
        var kids = new List<CheckNode>();
        foreach (var c in e.Elements())
        {
            var k = c.Name.LocalName == "complex-check" ? ComplexNode(c, profile, externals)
                  : c.Name.LocalName == "check" && c.At("system") == OvalSystem ? OvalNode(c, profile, externals) : null;
            // a part that can't run makes the answer "not checked", so it must stay in the tree
            if (c.Name.LocalName is "check" or "complex-check") kids.Add(k ?? new CheckNode());
        }
        return kids.All(k => k.Definition == null && k.Children.Count == 0) ? null
            : new CheckNode { Operator = e.At("operator") == "OR" ? "OR" : "AND", Negate = X.IsTrue(e.At("negate")), Children = kids };
    }

    string? SceScript(XElement check, XccdfProfile? profile)
    {
        foreach (var c in check.Els("check-content-ref"))
        {
            var body = Source?.Find(c.At("href"));
            if (body == null || body.Name.LocalName != "script") continue;
            var sb = new StringBuilder("XCCDF_RESULT_PASS=101 XCCDF_RESULT_FAIL=102 XCCDF_RESULT_ERROR=103 XCCDF_RESULT_UNKNOWN=104 XCCDF_RESULT_NOT_APPLICABLE=105 XCCDF_RESULT_NOT_CHECKED=106 XCCDF_RESULT_NOT_SELECTED=107 XCCDF_RESULT_INFORMATIONAL=108 XCCDF_RESULT_FIXED=109\n")
                .Append("export XCCDF_RESULT_PASS XCCDF_RESULT_FAIL XCCDF_RESULT_ERROR XCCDF_RESULT_UNKNOWN XCCDF_RESULT_NOT_APPLICABLE XCCDF_RESULT_NOT_CHECKED XCCDF_RESULT_NOT_SELECTED XCCDF_RESULT_INFORMATIONAL XCCDF_RESULT_FIXED\n");
            foreach (var e in check.Els("check-export"))
            {
                var name = System.Text.RegularExpressions.Regex.Replace(e.At("export-name"), "[^A-Za-z0-9_]", "_");
                if (name.Length > 0) sb.Append($"XCCDF_VALUE_{name}={ScriptBuilder.Q(Value(e.At("value-id"), profile) ?? "")}; export XCCDF_VALUE_{name}\n");
            }
            return sb.Append(body.Value.Trim()).ToString();
        }
        return null;
    }

    string? Question(List<XElement> checks)
    {
        foreach (var c in checks)
        {
            var content = c.El("check-content");
            if (content != null && content.Value.Trim().Length > 0) return Cut(content.Text());
            if (!c.At("system").Contains("ocil", StringComparison.OrdinalIgnoreCase)) continue;
            foreach (var rf in c.Els("check-content-ref"))
            {
                Source?.Find(rf.At("href"));
                foreach (var o in Source?.Ocil ?? new List<XElement>())
                {
                    var q = o.Descendants().FirstOrDefault(e => e.Name.LocalName == "questionnaire" && e.At("id") == rf.At("name"));
                    var action = q?.Descendants().FirstOrDefault(e => e.Name.LocalName == "test_action_ref")?.Value.Trim();
                    var a = action == null ? null : o.Descendants().FirstOrDefault(e => e.Name.LocalName.EndsWith("_test_action", StringComparison.Ordinal) && e.At("id") == action);
                    var qid = a?.At("question_ref");
                    var text = qid == null ? null : o.Descendants().FirstOrDefault(e => e.Name.LocalName.EndsWith("_question", StringComparison.Ordinal) && e.At("id") == qid)?.El("question_text");
                    if (text != null && text.Text().Length > 0) return Cut(text.Text());
                }
            }
        }
        return null;
    }

    static string Cut(string s) => s.Length > 1000 ? s[..1000] + "..." : s;

    // ---------------------------------------------------------------- platforms (CPE)
    PlatformNode? PlatformFor(XccdfRule r)
    {
        var levels = new List<PlatformNode>();
        void Add(List<string> names)
        {
            if (names.Count == 0) return;
            var nodes = names.Select(Platform).ToList();
            if (nodes.Any(n => n == null)) return;   // unknown platform: don't hide the rule because of it
            levels.Add(nodes.Count == 1 ? nodes[0]! : new PlatformNode { Operator = "OR", Children = nodes!.ToList<PlatformNode>() });
        }
        Add(r.Platforms);
        foreach (var g in r.Ancestors()) Add(g.Platforms);
        Add(Platforms);
        return levels.Count switch
        {
            0 => null,
            1 => levels[0],
            _ => new PlatformNode { Operator = "AND", Children = levels }
        };
    }

    PlatformNode? Platform(string idref)
    {
        if (platformCache.TryGetValue(idref, out var n)) return n;
        n = FindPlatform(idref);
        if (n == null) UnknownPlatforms.Add(idref);
        return platformCache[idref] = n;
    }

    PlatformNode? FindPlatform(string idref)
    {
        if (Source == null) return null;
        if (idref.StartsWith('#'))
        {
            var id = idref[1..];
            var spec = Source.Benchmark?.Descendants().FirstOrDefault(e => e.Name.LocalName == "platform" && e.At("id") == id);
            var test = spec?.El("logical-test");
            return test == null ? null : Logical(test);
        }
        foreach (var d in Source.Dictionaries)
        {
            var item = d.Els("cpe-item").FirstOrDefault(i => i.At("name") == idref)
                       ?? d.Els("cpe-item").FirstOrDefault(i => CpeMatch(idref, i.At("name")));
            var check = item?.El("check");
            if (check == null) continue;
            var def = check.Value.Trim();
            Source.Find(check.At("href"));
            RefreshOval();
            if (Oval?.Get(def) != null) return new PlatformNode { Definition = def };
        }
        return null;
    }

    PlatformNode? Logical(XElement t)
    {
        var kids = new List<PlatformNode>();
        foreach (var c in t.Elements())
        {
            PlatformNode? k = null;
            switch (c.Name.LocalName)
            {
                case "logical-test": k = Logical(c); break;
                case "fact-ref": k = Platform(c.At("name")); break;
                case "check-fact-ref":
                    Source!.Find(c.At("href"));
                    RefreshOval();
                    if (Oval?.Get(c.At("id-ref")) != null) k = new PlatformNode { Definition = c.At("id-ref") };
                    break;
                default: continue;
            }
            if (k == null) return null;
            kids.Add(k);
        }
        return kids.Count == 0 ? null : new PlatformNode { Operator = t.At("operator") == "OR" ? "OR" : "AND", Negate = X.IsTrue(t.At("negate")), Children = kids };
    }

    /// cpe:/o:vendor:product:version : an empty part on either side matches anything
    static bool CpeMatch(string a, string b)
    {
        if (!a.StartsWith("cpe:/", StringComparison.Ordinal) || !b.StartsWith("cpe:/", StringComparison.Ordinal)) return false;
        var x = a[5..].Split(':'); var y = b[5..].Split(':');
        for (int i = 0; i < Math.Min(x.Length, y.Length); i++)
            if (x[i].Length > 0 && y[i].Length > 0 && x[i] != "-" && y[i] != "-" && !x[i].Equals(y[i], StringComparison.OrdinalIgnoreCase)) return false;
        return x.Length >= 3 && y.Length >= 3;
    }
}
