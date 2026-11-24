namespace ScriptIX.Scap;

public sealed record CvssScore(string Version, double Base, double? Temporal, double? Environmental)
{
    public double Overall => Environmental ?? Temporal ?? Base;
    public string Rating => Version == "2.0"
        ? Overall >= 7 ? "High" : Overall >= 4 ? "Medium" : "Low"
        : Overall >= 9 ? "Critical" : Overall >= 7 ? "High" : Overall >= 4 ? "Medium" : Overall > 0 ? "Low" : "None";
}

/// <summary>CVSS 2.0, 3.0 and 3.1 scores from a vector string.</summary>
public static class Cvss
{
    public static CvssScore Score(string vector)
    {
        var v = vector.Trim().Trim('(', ')');
        if (v.StartsWith("CVSS:3.", StringComparison.Ordinal)) return V3(v);
        if (v.StartsWith("CVSS:4", StringComparison.Ordinal)) throw new FormatException("CVSS 4.0 isn't supported. Use a CVSS 2.0, 3.0 or 3.1 vector.");
        if (v.StartsWith("AV:", StringComparison.Ordinal)) return V2(v);
        throw new FormatException("Not a CVSS vector. Example: CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H");
    }

    static Dictionary<string, string> Parse(string v)
    {
        var d = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in v.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            var i = part.IndexOf(':');
            if (i <= 0 || i == part.Length - 1) throw new FormatException($"Not a CVSS metric: {part}");
            if (!d.TryAdd(part[..i], part[(i + 1)..])) throw new FormatException($"Metric given twice: {part[..i]}");
        }
        return d;
    }

    static double Pick(Dictionary<string, string> d, string key, string choices, string? fallback = null)
    {
        var val = d.TryGetValue(key, out var s) ? s : fallback ?? throw new FormatException($"The vector has no {key} metric.");
        foreach (var c in choices.Split(' '))
        {
            var i = c.IndexOf('=');
            if (c[..i] == val) return double.Parse(c[(i + 1)..], System.Globalization.CultureInfo.InvariantCulture);
        }
        throw new FormatException($"{key}:{val} isn't a valid metric value.");
    }

    // ---------------------------------------------------------------- 3.x
    static CvssScore V3(string vector)
    {
        var version = vector.Split('/')[0][5..];
        if (version is not ("3.0" or "3.1")) throw new FormatException($"CVSS {version} isn't supported.");
        var d = Parse(vector[(vector.IndexOf('/') + 1)..]);
        double Up(double x) => version == "3.1" ? RoundUp31(x) : Math.Ceiling(Math.Round(x * 10, 8)) / 10;

        const string AV = "N=0.85 A=0.62 L=0.55 P=0.2", AC = "L=0.77 H=0.44", UI = "N=0.85 R=0.62", CIA = "H=0.56 L=0.22 N=0";
        const string PrU = "N=0.85 L=0.62 H=0.27", PrC = "N=0.85 L=0.68 H=0.5";
        bool changed = Pick(d, "S", "U=0 C=1") == 1;
        double iss = 1 - (1 - Pick(d, "C", CIA)) * (1 - Pick(d, "I", CIA)) * (1 - Pick(d, "A", CIA));
        double impact = changed ? 7.52 * (iss - 0.029) - 3.25 * Math.Pow(iss - 0.02, 15) : 6.42 * iss;
        double expl = 8.22 * Pick(d, "AV", AV) * Pick(d, "AC", AC) * Pick(d, "PR", changed ? PrC : PrU) * Pick(d, "UI", UI);
        double baseScore = impact <= 0 ? 0 : Up(Math.Min((changed ? 1.08 : 1) * (impact + expl), 10));

        const string E = "X=1 U=0.91 P=0.94 F=0.97 H=1", RL = "X=1 O=0.95 T=0.96 W=0.97 U=1", RC = "X=1 U=0.92 R=0.96 C=1";
        double t = Pick(d, "E", E, "X") * Pick(d, "RL", RL, "X") * Pick(d, "RC", RC, "X");
        double? temporal = d.ContainsKey("E") || d.ContainsKey("RL") || d.ContainsKey("RC") ? Up(baseScore * t) : null;

        var envKeys = new[] { "CR", "IR", "AR", "MAV", "MAC", "MPR", "MUI", "MS", "MC", "MI", "MA" };
        double? env = null;
        if (envKeys.Any(d.ContainsKey))
        {
            string M(string k) => d.TryGetValue("M" + k, out var m) && m != "X" ? m : d[k];
            double P(string k, string choices) => Pick(new Dictionary<string, string> { [k] = M(k) }, k, choices);
            const string R = "X=1 L=0.5 M=1 H=1.5";
            bool mc = M("S") == "C";
            double miss = Math.Min(1 - (1 - Pick(d, "CR", R, "X") * P("C", CIA)) * (1 - Pick(d, "IR", R, "X") * P("I", CIA)) * (1 - Pick(d, "AR", R, "X") * P("A", CIA)), 0.915);
            double mi = !mc ? 6.42 * miss
                : version == "3.1" ? 7.52 * (miss - 0.029) - 3.25 * Math.Pow(miss * 0.9731 - 0.02, 13) : 7.52 * (miss - 0.029) - 3.25 * Math.Pow(miss - 0.02, 15);
            double me = 8.22 * P("AV", AV) * P("AC", AC) * P("PR", mc ? PrC : PrU) * P("UI", UI);
            env = mi <= 0 ? 0 : Up(Up(Math.Min((mc ? 1.08 : 1) * (mi + me), 10)) * t);
        }
        return new CvssScore(version, baseScore, temporal, env);
    }

    static double RoundUp31(double x)
    {
        int i = (int)Math.Round(x * 100000);
        return i % 10000 == 0 ? i / 100000.0 : (Math.Floor(i / 10000.0) + 1) / 10.0;
    }

    // ---------------------------------------------------------------- 2.0
    static CvssScore V2(string vector)
    {
        var d = Parse(vector);
        static double R1(double x) => Math.Round(x, 1, MidpointRounding.AwayFromZero);
        const string CIA = "N=0 P=0.275 C=0.66";
        double c = Pick(d, "C", CIA), i = Pick(d, "I", CIA), a = Pick(d, "A", CIA);
        double expl = 20 * Pick(d, "AV", "L=0.395 A=0.646 N=1") * Pick(d, "AC", "H=0.35 M=0.61 L=0.71") * Pick(d, "Au", "M=0.45 S=0.56 N=0.704");
        double BaseOf(double impact) => R1((0.6 * impact + 0.4 * expl - 1.5) * (impact == 0 ? 0 : 1.176));
        double baseScore = BaseOf(10.41 * (1 - (1 - c) * (1 - i) * (1 - a)));

        double t = Pick(d, "E", "U=0.85 POC=0.9 F=0.95 H=1 ND=1", "ND") * Pick(d, "RL", "OF=0.87 TF=0.9 W=0.95 U=1 ND=1", "ND") * Pick(d, "RC", "UC=0.9 UR=0.95 C=1 ND=1", "ND");
        double? temporal = d.ContainsKey("E") || d.ContainsKey("RL") || d.ContainsKey("RC") ? R1(baseScore * t) : null;
        double? env = null;
        if (new[] { "CDP", "TD", "CR", "IR", "AR" }.Any(d.ContainsKey))
        {
            const string R = "L=0.5 M=1 H=1.51 ND=1";
            double impact = Math.Min(10, 10.41 * (1 - (1 - c * Pick(d, "CR", R, "ND")) * (1 - i * Pick(d, "IR", R, "ND")) * (1 - a * Pick(d, "AR", R, "ND"))));
            double at = R1(BaseOf(impact) * t);
            env = R1((at + (10 - at) * Pick(d, "CDP", "N=0 L=0.1 LM=0.3 MH=0.4 H=0.5 ND=0", "ND")) * Pick(d, "TD", "N=0 L=0.25 M=0.75 H=1 ND=1", "ND"));
        }
        return new CvssScore("2.0", baseScore, temporal, env);
    }
}
