using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace ScriptIX.Scap;

/// <summary>Reads and writes XCCDF 1.2 tailoring files (the same kind SCAP Workbench makes).</summary>
public static class Tailoring
{
    static readonly XNamespace Ns = "http://checklists.nist.gov/xccdf/1.2";

    /// Adds the profiles of a tailoring file to the document and returns them.
    public static List<XccdfProfile> Load(XccdfDocument doc, Stream s, CancellationToken ct = default)
    {
        var root = ScapSource.ReadXml(s, ct).Root;
        if (root == null || root.Name.LocalName != "Tailoring")
            throw new FormatException("This isn't an XCCDF tailoring file.");
        var target = root.El("benchmark")?.At("id") ?? "";
        if (target.Length > 0 && doc.Id.Length > 0 && target != doc.Id)
            throw new FormatException($"This tailoring file belongs to another benchmark ({target}).");
        var added = root.Els("Profile").Select(p => XccdfImporter.ParseProfile(p, true)).ToList();
        if (added.Count == 0) throw new FormatException("The tailoring file has no profile.");
        foreach (var p in added)
        {
            var missing = p.Extends.TrimStart('#');
            if (missing.Length > 0 && doc.Profiles.All(q => q.Id != missing) && added.All(q => q.Id != missing))
                throw new FormatException($"The tailoring extends profile {missing}, which isn't in this benchmark.");
            // a tailored profile may have the id of the profile it extends: that one must stay
            doc.Profiles.RemoveAll(q => q.Id == p.Id && (q.Tailored || p.Extends.TrimStart('#') != p.Id));
        }
        doc.Profiles.InsertRange(0, added);
        doc.ResolveProfiles();
        return added;
    }

    /// <param name="selected">full ids of the rules that must be in the profile</param>
    public static string Write(XccdfDocument doc, XccdfProfile? basis, string title, IReadOnlySet<string> selected, DateTime now)
    {
        // start from the benchmark's own profile, so the file works with the original benchmark alone
        var start = basis;
        while (start is { Tailored: true })
            start = doc.Profiles.FirstOrDefault(p => p.Id == start.Extends.TrimStart('#') && p != start && !p.Tailored);

        var work = new XccdfProfile { Id = "work", Extends = start?.Id ?? "" };
        bool Has(string id) => work.Selected.Contains(id);
        doc.Resolve(work);
        // rules can only be on when every group above them is on
        foreach (var g in doc.Rules.Where(r => selected.Contains(r.Id) && !Has(r.Id)).SelectMany(r => r.Ancestors()).Distinct())
            work.Ops.Add(new ProfileOp("select", g.Id, "true"));
        doc.Resolve(work);
        foreach (var r in doc.Rules)
            if (Has(r.Id) != selected.Contains(r.Id)) work.Ops.Add(new ProfileOp("select", r.Id, selected.Contains(r.Id) ? "true" : "false"));
        doc.Resolve(work);

        var values = new List<XElement>();
        foreach (var v in doc.Values.Values)
        {
            var want = doc.Value(v.Id, basis);
            if (want == null || want == doc.ProfileValue(v.Id, start)) continue;
            var sel = v.BySelector.FirstOrDefault(kv => kv.Value == want).Key;
            values.Add(sel != null
                ? new XElement(Ns + "refine-value", new XAttribute("idref", v.Id), new XAttribute("selector", sel))
                : new XElement(Ns + "set-value", new XAttribute("idref", v.Id), want));
        }
        var name = Regex.Replace(title.Trim().ToLowerInvariant(), "[^a-z0-9.-]+", "-").Trim('-');
        if (name.Length == 0) name = "custom";
        var profile = new XElement(Ns + "Profile", new XAttribute("id", "xccdf_org.scriptix.content_profile_" + name));
        if (start != null) profile.Add(new XAttribute("extends", start.Id));
        profile.Add(new XElement(Ns + "title", new XAttribute(XNamespace.Xml + "lang", "en-US"), new XAttribute("override", "true"), title.Trim().Length > 0 ? title.Trim() : "Custom profile"));
        profile.Add(new XElement(Ns + "description", new XAttribute(XNamespace.Xml + "lang", "en-US"), new XAttribute("override", "true"), $"Made with {AppInfo.Name} {AppInfo.Version}."));
        foreach (var o in work.Ops)
            profile.Add(new XElement(Ns + "select", new XAttribute("idref", o.Id), new XAttribute("selected", o.Value)));
        profile.Add(values);

        var root = new XElement(Ns + "Tailoring", new XAttribute(XNamespace.Xmlns + "xccdf", Ns), new XAttribute("id", "xccdf_org.scriptix.content_tailoring_" + name),
            new XElement(Ns + "benchmark", new XAttribute("href", doc.FileName.Length > 0 ? doc.FileName : doc.Id)),
            new XElement(Ns + "version", new XAttribute("time", now.ToString("yyyy-MM-ddTHH:mm:ss")), "1"),
            profile);
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + root + "\n";
    }
}
