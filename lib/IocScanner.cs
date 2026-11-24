// IOC search over EZ Tools CSV output. Compiled by EZTriage.Engine.psm1 the first time a search runs
// (C# 5, so it builds with the compiler that ships with Windows PowerShell 5.1).
//
// Design limits, so a search never runs out of memory on multi-GB CSVs:
// - files are streamed one record at a time; nothing is loaded whole
// - hits are written to the output as they are found
// - at most Cap hits per IOC per file are saved (counting continues past the cap)
// - saved row details are trimmed to MaxDetail characters (matching always uses the full row)
// - a record with unbalanced quotes stops growing at MaxRecordChars
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;

namespace EZTriage
{
    public class IocFileResult
    {
        public long[] Counts;        // matching rows per IOC (not capped)
        public long Records;         // data rows read (header excluded)
        public int BrokenRecords;    // records cut at MaxRecordChars (unbalanced quotes)
        public bool Cancelled;
    }

    public class IocScanner
    {
        private readonly string[] iocs;
        private readonly string[] folded;
        private readonly bool[] isIp;
        // Aho-Corasick automaton over case-folded characters: every IOC is found in one pass.
        private readonly List<Dictionary<char, int>> next = new List<Dictionary<char, int>>();
        private readonly List<int> fail = new List<int>();
        private readonly List<int[]> outs = new List<int[]>();
        private readonly int[] rootNext = new int[65536];

        public int Cap = 10000;
        public int MaxDetail = 32000;
        public int MaxRecordChars = 16 * 1024 * 1024;
        public volatile bool Cancel;
        private long bytesRead;
        public long BytesRead { get { return Interlocked.Read(ref bytesRead); } }

        // Timestamp column shown in the results, by preference. Otherwise the first column whose
        // name looks like a time. The column name is saved with the value, so it is never ambiguous.
        private static readonly string[] PreferredTime = {
            "TimeCreated", "UpdateTimestamp", "RunTime", "LastRun", "DeletedOn", "LastModifiedTimeUTC",
            "LastWriteTimestamp", "FileKeyLastWriteTimestamp", "KeyLastWriteTimestamp", "LastWriteTime",
            "Timestamp", "SourceModified", "LastModified", "StartTime", "LastInteracted",
            "LastModified0x10", "Created0x10" };

        public IocScanner(string[] iocs, bool[] isIp)
        {
            this.iocs = iocs;
            this.isIp = isIp;
            folded = new string[iocs.Length];
            var tmp = new List<List<int>>();
            next.Add(new Dictionary<char, int>()); fail.Add(0); tmp.Add(new List<int>());
            for (int k = 0; k < iocs.Length; k++)
            {
                string s = Fold(iocs[k]);
                folded[k] = s;
                if (s.Length == 0) continue;
                int node = 0;
                foreach (char c in s)
                {
                    int nx;
                    if (!next[node].TryGetValue(c, out nx))
                    {
                        nx = next.Count;
                        next.Add(new Dictionary<char, int>()); fail.Add(0); tmp.Add(new List<int>());
                        next[node][c] = nx;
                    }
                    node = nx;
                }
                tmp[node].Add(k);
            }
            var queue = new Queue<int>();
            foreach (var kv in next[0]) { rootNext[kv.Key] = kv.Value; queue.Enqueue(kv.Value); }
            while (queue.Count > 0)
            {
                int r = queue.Dequeue();
                foreach (var kv in next[r])
                {
                    int u = kv.Value;
                    queue.Enqueue(u);
                    int f = fail[r];
                    int t;
                    while (f != 0 && !next[f].ContainsKey(kv.Key)) f = fail[f];
                    fail[u] = next[f].TryGetValue(kv.Key, out t) ? t : 0;
                    tmp[u].AddRange(tmp[fail[u]]);
                }
            }
            foreach (var l in tmp) outs.Add(l.ToArray());
        }

        private static char F(char c)
        {
            if (c < 128) return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
            return char.ToLowerInvariant(c);
        }

        private static string Fold(string s)
        {
            var a = s.ToCharArray();
            for (int i = 0; i < a.Length; i++) a[i] = F(a[i]);
            return new string(a);
        }

        private int Step(int state, char c)
        {
            while (true)
            {
                if (state == 0) return rootNext[c];
                int nx;
                if (next[state].TryGetValue(c, out nx)) return nx;
                state = fail[state];
            }
        }

        private static bool IsDigit(char c) { return c >= '0' && c <= '9'; }

        // 10.1.1.1 must not match inside 10.1.1.10 or 110.1.1.1.
        private static bool IpBoundary(string s, int start, int end)
        {
            int b = start - 1;
            if (b >= 0 && (IsDigit(s[b]) || (s[b] == '.' && b > 0 && IsDigit(s[b - 1])))) return false;
            int a = end + 1;
            if (a < s.Length && (IsDigit(s[a]) || (s[a] == '.' && a + 1 < s.Length && IsDigit(s[a + 1])))) return false;
            return true;
        }

        private void FindMatches(string rec, int recNo, int[] seenAt, List<int> found)
        {
            int state = 0;
            for (int i = 0; i < rec.Length; i++)
            {
                state = Step(state, F(rec[i]));
                int[] o = outs[state];
                for (int j = 0; j < o.Length; j++)
                {
                    int k = o[j];
                    if (seenAt[k] == recNo) continue;
                    if (isIp[k] && !IpBoundary(rec, i - folded[k].Length + 1, i)) continue;
                    seenAt[k] = recNo;
                    found.Add(k);
                }
            }
        }

        private bool FieldContains(string field, int k)
        {
            int from = 0;
            while (true)
            {
                int p = field.IndexOf(iocs[k], from, StringComparison.OrdinalIgnoreCase);
                if (p < 0) return false;
                if (!isIp[k] || IpBoundary(field, p, p + iocs[k].Length - 1)) return true;
                from = p + 1;
            }
        }

        private static int CountQuotes(string s)
        {
            int n = 0;
            for (int i = 0; i < s.Length; i++) if (s[i] == '"') n++;
            return n;
        }

        private static List<string> ParseCsv(string s)
        {
            var list = new List<string>();
            var sb = new StringBuilder();
            bool inQ = false;
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (inQ)
                {
                    if (c == '"')
                    {
                        if (i + 1 < s.Length && s[i + 1] == '"') { sb.Append('"'); i++; }
                        else inQ = false;
                    }
                    else sb.Append(c);
                }
                else if (c == '"') inQ = true;
                else if (c == ',') { list.Add(sb.ToString()); sb.Length = 0; }
                else sb.Append(c);
            }
            list.Add(sb.ToString());
            return list;
        }

        private static int[] PickTimeColumns(string[] header)
        {
            var cols = new List<int>();
            foreach (string p in PreferredTime)
                for (int i = 0; i < header.Length; i++)
                    if (string.Equals(header[i], p, StringComparison.OrdinalIgnoreCase) && !cols.Contains(i)) cols.Add(i);
            for (int i = 0; i < header.Length; i++)
            {
                string h = Fold(header[i]);
                if (h.Contains("zone") || cols.Contains(i)) continue;
                if (h.Contains("time") || h.Contains("date") || h.Contains("created") || h.Contains("modified") ||
                    h.Contains("lastrun") || h.Contains("deleted")) cols.Add(i);
            }
            return cols.ToArray();
        }

        private static string Csv(string s) { return "\"" + s.Replace("\"", "\"\"") + "\""; }

        private static string ColumnName(string[] header, int i)
        {
            return (i < header.Length && header[i].Length > 0) ? header[i] : "Column " + (i + 1);
        }

        private void WriteHit(TextWriter w, int k, string host, string source, long line,
                              string[] header, int[] timeCols, List<string> fields)
        {
            string column = "(across columns)";
            for (int i = 0; i < fields.Count; i++)
                if (FieldContains(fields[i], k)) { column = ColumnName(header, i); break; }

            string time = "", timeCol = "";
            foreach (int t in timeCols)
            {
                if (t >= fields.Count) continue;
                string v = fields[t].Trim();
                if (v.Length > 0 && IsDigit(v[0])) { time = v; timeCol = header[t]; break; }
            }

            // "Name: value | Name: value" for every non-empty field, one line, trimmed.
            var d = new StringBuilder();
            for (int i = 0; i < fields.Count; i++)
            {
                string v = fields[i];
                if (v.Trim().Length == 0) continue;
                if (d.Length > 0) d.Append(" | ");
                d.Append(ColumnName(header, i)).Append(": ").Append(v);
                if (d.Length > MaxDetail) break;
            }
            d.Replace('\r', ' ').Replace('\n', ' ');
            string details = d.Length > MaxDetail ? d.ToString(0, MaxDetail) + " ...[trimmed]" : d.ToString();

            w.Write(Csv(time)); w.Write(',');
            w.Write(Csv(timeCol)); w.Write(',');
            w.Write(Csv(iocs[k])); w.Write(',');
            w.Write(Csv(host)); w.Write(',');
            w.Write(Csv(source)); w.Write(',');
            w.Write(line); w.Write(',');
            w.Write(Csv(column)); w.Write(',');
            w.WriteLine(Csv(details));
        }

        public static string HitsHeader
        {
            // SourceLine, not Line: Timeline Explorer adds a Line column of its own.
            get { return "Time,TimeColumn,Ioc,Host,Source,SourceLine,Column,Details"; }
        }

        public IocFileResult ScanFile(string path, string host, string source, TextWriter hits)
        {
            var res = new IocFileResult();
            res.Counts = new long[iocs.Length];
            Interlocked.Exchange(ref bytesRead, 0);
            var seenAt = new int[iocs.Length];
            var found = new List<int>();
            var sb = new StringBuilder();
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20, FileOptions.SequentialScan))
            using (var reader = new StreamReader(fs, new UTF8Encoding(false), true, 1 << 20))
            {
                long lineNo = 0;
                string[] header = null;
                int[] timeCols = null;
                int recNo = 0;
                while (true)
                {
                    string line = reader.ReadLine();
                    if (line == null) break;
                    lineNo++;
                    long startLine = lineNo;
                    string rec = line;
                    int q = CountQuotes(line);
                    if ((q & 1) == 1)
                    {
                        // A quoted field continues on the next line (event log script blocks, for example).
                        sb.Length = 0;
                        sb.Append(line);
                        while ((q & 1) == 1)
                        {
                            string more = reader.ReadLine();
                            if (more == null) break;
                            lineNo++;
                            sb.Append('\n').Append(more);
                            q += CountQuotes(more);
                            if (sb.Length > MaxRecordChars) { res.BrokenRecords++; break; }
                        }
                        rec = sb.ToString();
                    }
                    if (header == null)
                    {
                        header = ParseCsv(rec).ToArray();
                        timeCols = PickTimeColumns(header);
                        continue;
                    }
                    recNo++;
                    res.Records++;
                    if ((recNo & 1023) == 0)
                    {
                        Interlocked.Exchange(ref bytesRead, fs.Position);
                        if (Cancel) { res.Cancelled = true; break; }
                    }
                    found.Clear();
                    FindMatches(rec, recNo, seenAt, found);
                    if (found.Count == 0) continue;
                    List<string> fields = null;
                    foreach (int k in found)
                    {
                        res.Counts[k]++;
                        if (res.Counts[k] > Cap) continue;
                        if (fields == null) fields = ParseCsv(rec);
                        WriteHit(hits, k, host, source, startLine, header, timeCols, fields);
                    }
                }
                Interlocked.Exchange(ref bytesRead, fs.Position);
            }
            return res;
        }
    }
}
