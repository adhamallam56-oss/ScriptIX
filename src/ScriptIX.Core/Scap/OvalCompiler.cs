using System.Text;
using System.Xml.Linq;

namespace ScriptIX.Scap;

/// <summary>All OVAL files of a source, indexed by id.</summary>
public sealed class OvalLibrary
{
    readonly Dictionary<string, XElement> items = new(StringComparer.Ordinal);
    public int DefinitionCount { get; private set; }

    public OvalLibrary(IEnumerable<XElement> roots)
    {
        foreach (var root in roots)
            foreach (var section in root.Elements())
                if (section.Name.LocalName is "definitions" or "tests" or "objects" or "states" or "variables")
                    foreach (var e in section.Elements())
                    {
                        var id = e.At("id");
                        if (id.Length == 0 || !items.TryAdd(id, e)) continue;
                        if (section.Name.LocalName == "definitions") DefinitionCount++;
                    }
    }

    public XElement? Get(string id) => items.TryGetValue(id, out var e) ? e : null;
    public IEnumerable<XElement> Definitions => items.Values.Where(e => e.Name.LocalName == "definition");
    public IEnumerable<XElement> Tests => items.Values.Where(e => e.Name.LocalName.EndsWith("_test", StringComparison.Ordinal));
}

/// <summary>
/// Turns one check (and everything it refers to) into the small text form the awk engine reads.
/// A test the engine can't do is marked "?", which ends as "not checked" and never as a pass.
/// </summary>
public sealed class OvalCompiler
{
    // kind -> (object entities, state entities) the engine understands
    static readonly Dictionary<string, (string Objects, string States)> Kinds = new(StringComparer.Ordinal)
    {
        ["independent:textfilecontent54"] = ("filepath path filename pattern instance", "filepath path filename pattern instance text subexpression"),
        ["independent:family"] = ("", "family"),
        ["independent:environmentvariable58"] = ("pid name", "pid name value"),
        ["independent:environmentvariable"] = ("name", "name value"),
        ["independent:variable"] = ("var_ref", "var_ref value"),
        ["independent:filehash58"] = ("filepath path filename hash_type", "filepath path filename hash_type hash"),
        ["unix:file"] = ("filepath path filename", "filepath path filename type user_id group_id size suid sgid sticky uread uwrite uexec gread gwrite gexec oread owrite oexec has_extended_acl"),
        ["unix:uname"] = ("", "machine_class node_name os_name os_release os_version processor_type"),
        ["unix:password"] = ("username", "username password user_id group_id gcos home_dir login_shell"),
        ["unix:shadow"] = ("username", "username password chg_lst chg_allow chg_req exp_warn exp_inact exp_date flag encrypt_method"),
        ["unix:sysctl"] = ("name", "name value"),
        ["unix:symlink"] = ("filepath", "filepath canonical_path"),
        ["unix:interface"] = ("name", "name type inet_addr flag"),
        ["unix:process58"] = ("command_line pid", "command_line pid ppid ruid user_id"),
        ["unix:runlevel"] = ("service_name runlevel", "service_name runlevel start kill"),
        ["linux:dpkginfo"] = ("name", "name arch epoch version release evr"),
        ["linux:rpminfo"] = ("name", "name arch epoch version release evr signature_keyid extended_name"),
        ["linux:partition"] = ("mount_point", "mount_point device fs_type mount_options"),
        ["linux:systemdunitproperty"] = ("unit property", "unit property value"),
        ["linux:systemdunitdependency"] = ("unit", "unit dependency"),
        ["linux:inetlisteningservers"] = ("protocol local_address local_port", "protocol local_address local_port local_full_address"),
        ["linux:selinuxboolean"] = ("name", "name current_status pending_status"),
        ["linux:selinuxsecuritycontext"] = ("filepath path filename", "filepath path filename user role type"),
        ["aix:fileset"] = ("flstinst", "flstinst level state description"),
        ["aix:oslevel"] = ("", "maintenance_level"),
        ["aix:no"] = ("tunable", "tunable value"),
        ["aix:interim_fix"] = ("vuid", "vuid label state"),
    };

    static readonly HashSet<string> StringOps = new(StringComparer.Ordinal)
    {
        "equals", "not equal", "case insensitive equals", "case insensitive not equal", "greater than", "greater than or equal",
        "less than", "less than or equal", "pattern match", "bitwise and", "bitwise or", "subset of"
    };
    static readonly HashSet<string> DataTypes = new(StringComparer.Ordinal)
    {
        "", "string", "int", "float", "boolean", "evr_string", "debian_evr_string", "version", "fileset_revision", "ios_version", "ipv4_address", "binary"
    };

    readonly OvalLibrary lib;
    readonly IReadOnlyDictionary<string, IReadOnlyList<string>> externals;
    readonly StringBuilder sb = new();
    readonly HashSet<string> done = new(StringComparer.Ordinal);
    readonly Queue<string> todo = new();
    int nodes;

    /// Tests that the engine can't run: "kind" or "kind.entity".
    public SortedSet<string> Unsupported { get; } = new(StringComparer.Ordinal);

    OvalCompiler(OvalLibrary lib, IReadOnlyDictionary<string, IReadOnlyList<string>> externals)
    {
        this.lib = lib;
        this.externals = externals;
    }

    /// <param name="root">check reference: E + definition id, or a K node made with <see cref="Node"/></param>
    /// <param name="platform">applicability test tree, or null</param>
    public static (string Ir, IReadOnlyCollection<string> Unsupported) Compile(OvalLibrary lib, CheckNode? root, PlatformNode? platform,
        IReadOnlyDictionary<string, IReadOnlyList<string>> externals)
    {
        var c = new OvalCompiler(lib, externals);
        if (platform != null) c.Line("P", c.Platform(platform));
        c.Line("R", root == null ? "M" : c.Check(root));   // M: only the platform counts, the check is done by hand
        while (c.todo.Count > 0) c.Entity(c.todo.Dequeue());
        return (c.sb.ToString(), c.Unsupported);
    }

    // ---------------------------------------------------------------- output
    static string Esc(string s)
    {
        if (s.AsSpan().IndexOfAny("\\\t\n\r") < 0) return s;
        return s.Replace("\\", "\\\\").Replace("\t", "\\t").Replace("\n", "\\n").Replace("\r", "\\r");
    }

    void Line(params string[] f) => sb.Append(string.Join('\t', f)).Append('\n');

    string Use(string id)
    {
        if (id.Length > 0 && done.Add(id)) todo.Enqueue(id);
        return Safe(id);
    }

    static string Safe(string id) => id.Replace('\t', '_').Replace('\n', '_').Replace(' ', '_');

    string NewNode(string type, string op, bool negate, IReadOnlyList<string> children)
    {
        var id = "n" + ++nodes;
        if (children.Count == 0) Line(type, id, op, negate ? "1" : "0");
        for (int i = 0; i < children.Count; i += 20)   // short lines: old awks limit fields and line length
            Line(new[] { type, id, op, negate ? "1" : "0" }.Concat(children.Skip(i).Take(20)).ToArray());
        return id;
    }

    // ---------------------------------------------------------------- roots
    string Check(CheckNode n)
    {
        if (n.Definition != null) { Use(n.Definition); return "E" + Safe(n.Definition); }
        return "K" + NewNode("K", n.Operator, n.Negate, n.Children.Select(Check).ToList());
    }

    string Platform(PlatformNode n)
    {
        if (n.Definition != null) { Use(n.Definition); return (n.Negate ? "!" : "") + "D" + Safe(n.Definition); }
        return "C" + NewNode("C", n.Operator, n.Negate, n.Children.Select(Platform).ToList());
    }

    // ---------------------------------------------------------------- entities
    void Entity(string id)
    {
        var e = lib.Get(id);
        if (e == null) return;   // the engine answers "error" for anything that is missing
        var n = e.Name.LocalName;
        if (n == "definition") Definition(id, e);
        else if (n.EndsWith("_test", StringComparison.Ordinal)) Test(id, e);
        else if (n.EndsWith("_object", StringComparison.Ordinal)) Object(id, e);
        else if (n.EndsWith("_state", StringComparison.Ordinal)) State(id, e);
        else if (n.EndsWith("_variable", StringComparison.Ordinal)) Variable(id, e);
    }

    void Definition(string id, XElement e)
    {
        var crit = e.El("criteria");
        Line("D", Safe(id), e.At("class"), crit == null ? "" : "C" + Criteria(crit));
    }

    string Criteria(XElement e)
    {
        var kids = new List<string>();
        foreach (var k in e.Elements())
        {
            var neg = X.IsTrue(k.At("negate")) ? "!" : "";
            switch (k.Name.LocalName)
            {
                case "criteria": kids.Add("C" + Criteria(k)); break;   // its own negate is in the node
                case "criterion": kids.Add(neg + "T" + Use(k.At("test_ref"))); break;
                case "extend_definition": kids.Add(neg + "D" + Use(k.At("definition_ref"))); break;
            }
        }
        var op = e.At("operator");
        return NewNode("C", op.Length == 0 ? "AND" : op, X.IsTrue(e.At("negate")), kids);
    }

    static string Family(XElement e)
    {
        var ns = e.Name.NamespaceName;
        int i = ns.IndexOf('#');
        return i < 0 ? "" : ns[(i + 1)..];
    }

    void Test(string id, XElement e)
    {
        var kind = e.Name.LocalName[..^5];
        var comment = Esc(Short(e.At("comment")));
        if (kind == "unknown") { Line("T", Safe(id), "unknown", "", "", "", "", comment); return; }
        var problem = Problem(e, kind);
        if (problem != null)
        {
            Unsupported.Add(problem);
            Line("T", Safe(id), "?", "", "", "", problem, comment);
            return;
        }
        var ce = e.At("check_existence"); var op = e.At("state_operator");
        var f = new List<string>
        {
            "T", Safe(id), kind, ce.Length == 0 ? "at_least_one_exists" : ce, e.At("check"), op.Length == 0 ? "AND" : op,
            Use(e.El("object")?.At("object_ref") ?? ""), comment
        };
        f.AddRange(e.Els("state").Select(s => Use(s.At("state_ref"))));
        Line(f.ToArray());
    }

    static string Short(string s) => s.Length > 200 ? s[..200] : s;

    /// What in this test the engine can't do, or null.
    string? Problem(XElement test, string kind)
    {
        if (!Kinds.TryGetValue(Family(test) + ":" + kind, out var known)) return kind;
        var o = lib.Get(test.El("object")?.At("object_ref") ?? "");
        if (o == null) return kind + " (object missing)";
        var p = ObjectProblem(o, kind, known.Objects.Split(' '), known.States.Split(' '), 0);
        if (p != null) return p;
        foreach (var s in test.Els("state"))
            if ((p = StateProblem(s.At("state_ref"), kind, known.States.Split(' '))) != null) return p;
        return null;
    }

    string? StateProblem(string id, string kind, string[] entities)
    {
        var s = lib.Get(id);
        if (s == null) return kind + " (state missing)";
        foreach (var e in s.Elements().Where(x => x.Name.LocalName is not "notes" and not "Signature"))
        {
            if (!entities.Contains(e.Name.LocalName)) return kind + "." + e.Name.LocalName;
            if (EntityProblem(e) is { } p) return kind + "." + e.Name.LocalName + " " + p;
        }
        return null;
    }

    static string? EntityProblem(XElement e)
    {
        var op = e.At("operation");
        if (op.Length > 0 && !StringOps.Contains(op)) return op;
        if (!DataTypes.Contains(e.At("datatype"))) return e.At("datatype");
        return null;
    }

    string? ObjectProblem(XElement o, string kind, string[] entities, string[] states, int depth)
    {
        if (depth > 8) return kind + " (nested too deep)";
        if (!o.Name.LocalName.Equals(kind + "_object", StringComparison.Ordinal)) return kind + " (wrong object)";
        if (o.El("set") is { } set) return SetProblem(set, kind, entities, states, depth);
        foreach (var e in o.Elements())
        {
            var n = e.Name.LocalName;
            if (n is "notes" or "Signature") continue;
            if (n == "filter") { if (StateProblem(e.Value.Trim(), kind, states) is { } p) return p; continue; }
            if (n == "behaviors")
            {
                if (e.At("recurse_direction") == "up") return kind + " recurse up";
                continue;
            }
            if (!entities.Contains(n)) return kind + "." + n;
            if (EntityProblem(e) is { } ep) return kind + "." + n + " " + ep;
            if (n is "filepath" or "path" && e.At("operation") is not ("" or "equals" or "pattern match")) return kind + "." + n + " " + e.At("operation");
            if (n == "pattern" && e.At("operation") is not "pattern match") return kind + ".pattern " + e.At("operation");
        }
        return null;
    }

    string? SetProblem(XElement set, string kind, string[] entities, string[] states, int depth)
    {
        foreach (var c in set.Elements())
        {
            string? p = null;
            switch (c.Name.LocalName)
            {
                case "set": p = SetProblem(c, kind, entities, states, depth + 1); break;
                case "filter": p = StateProblem(c.Value.Trim(), kind, states); break;
                case "object_reference":
                    var o = lib.Get(c.Value.Trim());
                    p = o == null ? kind + " (object missing)" : ObjectProblem(o, kind, entities, states, depth + 1);
                    break;
            }
            if (p != null) return p;
        }
        return null;
    }

    void Object(string id, XElement e)
    {
        var kind = e.Name.LocalName[..^7];
        if (e.El("set") is { } set) { Set(Safe(id), kind, set); return; }
        Line("O", Safe(id), kind);
        foreach (var x in e.Elements())
        {
            var n = x.Name.LocalName;
            switch (n)
            {
                case "notes" or "Signature": break;
                case "behaviors":
                    foreach (var a in x.Attributes()) Line("OB", Safe(id), a.Name.LocalName, a.Value);
                    break;
                case "filter":
                    Line("OF", Safe(id), x.At("action").Length == 0 ? "exclude" : x.At("action"), Use(x.Value.Trim()));
                    break;
                case "var_ref":
                    Line("OE", Safe(id), n, "equals", "string", "all", "lit", Use(x.Value.Trim()));
                    break;
                default:
                    var (src, val) = Source(x);
                    Line("OE", Safe(id), n, Or(x.At("operation"), "equals"), x.At("datatype"), Or(x.At("var_check"), "all"), src, val);
                    break;
            }
        }
    }

    void Set(string id, string kind, XElement set)
    {
        Line("O", id, kind);
        var members = new List<string>();
        int k = 0;
        foreach (var c in set.Elements())
        {
            if (c.Name.LocalName == "object_reference") members.Add(Use(c.Value.Trim()));
            else if (c.Name.LocalName == "set") { var sub = $"{id}.{++k}"; Set(sub, kind, c); members.Add(sub); }
        }
        foreach (var c in set.Els("filter"))
            Line("OF", id, c.At("action").Length == 0 ? "exclude" : c.At("action"), Use(c.Value.Trim()));
        Line(new[] { "OS", id, Or(set.At("set_operator"), "UNION") }.Concat(members).ToArray());
    }

    void State(string id, XElement e)
    {
        Line("S", Safe(id), Or(e.At("operator"), "AND"));
        foreach (var x in e.Elements().Where(x => x.Name.LocalName is not "notes" and not "Signature"))
        {
            var (src, val) = Source(x);
            Line("SE", Safe(id), x.Name.LocalName, Or(x.At("operation"), "equals"), x.At("datatype"), Or(x.At("entity_check"), "all"),
                 Or(x.At("var_check"), "all"), src, val);
        }
    }

    static string Or(string s, string d) => s.Length == 0 ? d : s;

    (string Src, string Val) Source(XElement x)
    {
        var v = x.At("var_ref");
        if (v.Length > 0) return ("var", Use(v));
        XNamespace xsi = "http://www.w3.org/2001/XMLSchema-instance";
        if (X.IsTrue((string?)x.Attribute(xsi + "nil") ?? "")) return ("nil", "");
        return ("lit", Esc(x.Value));
    }

    // ---------------------------------------------------------------- variables
    void Variable(string id, XElement e)
    {
        var sid = Safe(id);
        switch (e.Name.LocalName)
        {
            case "constant_variable":
                Line("V", sid, "const", "");
                foreach (var v in e.Els("value")) Line("VV", sid, Esc(v.Value));
                break;
            case "external_variable":
                Line("V", sid, "ext", "");
                if (externals.TryGetValue(id, out var vals)) foreach (var v in vals) Line("VV", sid, Esc(v));
                break;
            case "local_variable":
                var body = e.Elements().FirstOrDefault(x => x.Name.LocalName is not "notes" and not "Signature");
                Line("V", sid, "local", body == null ? Bad() : Component(body));
                break;
            default:
                Line("V", sid, "local", Bad());
                break;
        }
    }

    string Bad() { var id = "x" + ++nodes; Line("X", id, "bad"); return id; }

    string Component(XElement e)
    {
        var id = "x" + ++nodes;
        List<string> Kids() => e.Elements().Where(x => x.Name.LocalName is not "notes").Select(Component).ToList();
        void Put(string f, params string[] a) => Line(new[] { "X", id, f }.Concat(a).ToArray());
        switch (e.Name.LocalName)
        {
            case "literal_component": Put("lit", Esc(e.Value)); break;
            case "variable_component": Put("var", Use(e.At("var_ref"))); break;
            case "object_component":
                if (e.At("record_field").Length > 0) Put("bad");
                else Put("obj", Use(e.At("object_ref")), e.At("item_field"));
                break;
            case "concat": Put("concat", Kids().ToArray()); break;
            case "unique": Put("unique", Kids().ToArray()); break;
            case "count": Put("count", Kids().ToArray()); break;
            case "merge": Put("merge", Kids().ToArray()); break;
            case "escape_regex": Put("escape_regex", Kids().ToArray()); break;
            case "glob_to_regex": Put("glob_to_regex", Kids().ToArray()); break;
            case "arithmetic": Put("arithmetic", new[] { e.At("arithmetic_operation") }.Concat(Kids()).ToArray()); break;
            case "split": Put("split", Kids().Append(Esc(e.At("delimiter"))).ToArray()); break;
            case "regex_capture": Put("regex_capture", Kids().Append(Esc(e.At("pattern"))).ToArray()); break;
            case "substring": Put("substring", Kids().Append(e.At("substring_start")).Append(e.At("substring_length")).ToArray()); break;
            case "begin": Put("begin", Kids().Append(Esc(e.At("character"))).ToArray()); break;
            case "end": Put("end", Kids().Append(Esc(e.At("character"))).ToArray()); break;
            case "time_difference" when e.At("format_2") == "seconds_since_epoch":
                Put("time_difference", new[] { Or(e.At("format_1"), "year_month_day"), e.At("format_2") }.Concat(Kids()).ToArray());
                break;
            default:   // other time formats and anything newer: an error, so it can't turn into a pass
                Unsupported.Add("variable " + e.Name.LocalName);
                Put("bad");
                break;
        }
        return id;
    }
}

/// <summary>An XCCDF check: one OVAL definition, or AND/OR of others.</summary>
public sealed class CheckNode
{
    public string? Definition { get; init; }
    public string Operator { get; init; } = "AND";
    public bool Negate { get; init; }
    public List<CheckNode> Children { get; init; } = new();
}

/// <summary>Where a rule applies: one OVAL inventory definition, or AND/OR of others.</summary>
public sealed class PlatformNode
{
    public string? Definition { get; init; }
    public string Operator { get; init; } = "AND";
    public bool Negate { get; init; }
    public List<PlatformNode> Children { get; init; } = new();
}
