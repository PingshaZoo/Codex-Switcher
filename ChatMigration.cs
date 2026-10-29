using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexSwitcherSqlite
{
    const int Ok = 0;
    const int Row = 100;
    const int Done = 101;
    const int ReadOnly = 1;
    const int ReadWrite = 2;
    const int Create = 4;
    const int FullMutex = 0x10000;
    static readonly IntPtr Transient = new IntPtr(-1);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_close_v2(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr callback, IntPtr arg, out IntPtr error);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern void sqlite3_free(IntPtr value);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int bytes, out IntPtr statement, out IntPtr tail);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_step(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_finalize(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_text(IntPtr statement, int index);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern long sqlite3_column_int64(IntPtr statement, int index);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_bind_text(IntPtr statement, int index, byte[] value, int bytes, IntPtr destructor);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_backup_init(IntPtr destination, string destinationName, IntPtr source, string sourceName);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_backup_step(IntPtr backup, int pages);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_backup_finish(IntPtr backup);

    static byte[] Utf8Z(string value)
    {
        byte[] raw = Encoding.UTF8.GetBytes(value);
        byte[] result = new byte[raw.Length + 1];
        Buffer.BlockCopy(raw, 0, result, 0, raw.Length);
        return result;
    }

    static string Error(IntPtr db)
    {
        IntPtr value = sqlite3_errmsg(db);
        return value == IntPtr.Zero ? "unknown SQLite error" : Marshal.PtrToStringAnsi(value);
    }

    static IntPtr Open(string path, int flags)
    {
        IntPtr db;
        int rc = sqlite3_open_v2(Utf8Z(path), out db, flags | FullMutex, IntPtr.Zero);
        if (rc != Ok)
        {
            string message = db == IntPtr.Zero ? "unable to open database" : Error(db);
            if (db != IntPtr.Zero) sqlite3_close_v2(db);
            throw new InvalidOperationException(message);
        }
        return db;
    }

    static void Exec(IntPtr db, string sql)
    {
        IntPtr error;
        int rc = sqlite3_exec(db, Utf8Z(sql), IntPtr.Zero, IntPtr.Zero, out error);
        if (rc != Ok)
        {
            string message = error == IntPtr.Zero ? Error(db) : Marshal.PtrToStringAnsi(error);
            if (error != IntPtr.Zero) sqlite3_free(error);
            throw new InvalidOperationException(message);
        }
    }

    static IntPtr Prepare(IntPtr db, string sql)
    {
        IntPtr statement;
        IntPtr tail;
        byte[] bytes = Utf8Z(sql);
        int rc = sqlite3_prepare_v2(db, bytes, bytes.Length, out statement, out tail);
        if (rc != Ok) throw new InvalidOperationException(Error(db));
        return statement;
    }

    static string ScalarText(IntPtr db, string sql)
    {
        IntPtr statement = Prepare(db, sql);
        try
        {
            if (sqlite3_step(statement) != Row) throw new InvalidOperationException(Error(db));
            IntPtr value = sqlite3_column_text(statement, 0);
            return value == IntPtr.Zero ? null : Marshal.PtrToStringAnsi(value);
        }
        finally { sqlite3_finalize(statement); }
    }

    static long ScalarInt64(IntPtr db, string sql)
    {
        IntPtr statement = Prepare(db, sql);
        try
        {
            if (sqlite3_step(statement) != Row) throw new InvalidOperationException(Error(db));
            return sqlite3_column_int64(statement, 0);
        }
        finally { sqlite3_finalize(statement); }
    }

    static void CopyDatabase(IntPtr source, IntPtr destination)
    {
        IntPtr backup = sqlite3_backup_init(destination, "main", source, "main");
        if (backup == IntPtr.Zero) throw new InvalidOperationException(Error(destination));
        int step = sqlite3_backup_step(backup, -1);
        int finish = sqlite3_backup_finish(backup);
        if (step != Done || finish != Ok) throw new InvalidOperationException(Error(destination));
    }

    static void CheckSchema(IntPtr db)
    {
        if (ScalarText(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='threads'") != "threads")
            throw new InvalidOperationException("threads table is missing");
        ScalarInt64(db, "SELECT COUNT(*) FROM threads WHERE model_provider IS NULL AND model IS NULL");
        string integrity = ScalarText(db, "PRAGMA quick_check");
        if (integrity != "ok") throw new InvalidOperationException("SQLite quick_check failed: " + integrity);
    }

    static bool TableExists(IntPtr db, string table)
    {
        IntPtr statement = Prepare(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1");
        try
        {
            byte[] name = Encoding.UTF8.GetBytes(table);
            if (sqlite3_bind_text(statement, 1, name, name.Length, Transient) != Ok)
                throw new InvalidOperationException(Error(db));
            if (sqlite3_step(statement) != Row) throw new InvalidOperationException(Error(db));
            return sqlite3_column_int64(statement, 0) > 0;
        }
        finally { sqlite3_finalize(statement); }
    }

    static void CheckIntegrity(IntPtr db)
    {
        string integrity = ScalarText(db, "PRAGMA quick_check");
        if (integrity != "ok") throw new InvalidOperationException("SQLite quick_check failed: " + integrity);
    }

    public static bool HasThreadsTable(string path)
    {
        IntPtr db = IntPtr.Zero;
        try
        {
            db = Open(path, ReadOnly);
            return ScalarText(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='threads'") == "threads";
        }
        catch { return false; }
        finally { if (db != IntPtr.Zero) sqlite3_close_v2(db); }
    }

    // Test support only (used by tests\Test-DamagedSessions.ps1): create a minimal state database
    // that contains just the threads table, so the regression test does not need an external sqlite3
    // or python. The production switching flow never calls this. Keep this file ASCII-only on purpose:
    // Add-Type reads sources with the system code page when they have no BOM.
    public static void CreateEmptyStateDatabase(string path)
    {
        IntPtr db = IntPtr.Zero;
        try
        {
            db = Open(path, ReadWrite | Create);
            Exec(db, "DROP TABLE IF EXISTS threads");
            Exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER, updated_at INTEGER, source TEXT,"
                   + " model_provider TEXT, cwd TEXT, title TEXT, sandbox_policy TEXT, approval_mode TEXT, tokens_used INTEGER,"
                   + " has_user_event INTEGER, archived INTEGER, archived_at INTEGER, git_sha TEXT, git_branch TEXT, git_origin_url TEXT,"
                   + " cli_version TEXT, first_user_message TEXT, agent_nickname TEXT, agent_role TEXT, memory_mode TEXT, model TEXT,"
                   + " reasoning_effort TEXT, agent_path TEXT, created_at_ms INTEGER, updated_at_ms INTEGER, thread_source TEXT,"
                   + " preview TEXT, recency_at INTEGER, recency_at_ms INTEGER, history_mode TEXT, name TEXT, is_pinned INTEGER,"
                   + " thread_section_id TEXT, section_position INTEGER, section_entered_at_ms INTEGER, project_id TEXT,"
                   + " originator TEXT, daybreak_enabled INTEGER, creator_user_id TEXT, creator_account_id TEXT)");
            Exec(db, "INSERT INTO threads (id, model_provider, model, reasoning_effort, rollout_path, title, cwd)"
                   + " VALUES ('01a00000-0000-7000-8000-000000000001','deepseek','deepseek-flash','high','sessions/2026/10/06/rollout-test.jsonl','smoke test','C:/work')");
            CheckSchema(db);
        }
        finally { if (db != IntPtr.Zero) sqlite3_close_v2(db); }
    }


    public static long BackupAndUpdate(string databasePath, string backupPath, string provider, string model, string effort)
    {
        IntPtr source = IntPtr.Zero;
        IntPtr destination = IntPtr.Zero;
        IntPtr statement = IntPtr.Zero;
        bool transaction = false;
        try
        {
            source = Open(databasePath, ReadWrite);
            Exec(source, "PRAGMA busy_timeout=5000");
            CheckSchema(source);
            destination = Open(backupPath, ReadWrite | Create);
            CopyDatabase(source, destination);
            sqlite3_close_v2(destination);
            destination = IntPtr.Zero;
            Exec(source, "BEGIN IMMEDIATE");
            transaction = true;
            long count = ScalarInt64(source, "SELECT COUNT(*) FROM threads");
            statement = Prepare(source, "UPDATE threads SET model_provider=?1, model=?2, reasoning_effort=?3");
            byte[] providerBytes = Encoding.UTF8.GetBytes(provider);
            byte[] modelBytes = Encoding.UTF8.GetBytes(model);
            byte[] effortBytes = Encoding.UTF8.GetBytes(effort);
            if (sqlite3_bind_text(statement, 1, providerBytes, providerBytes.Length, Transient) != Ok ||
                sqlite3_bind_text(statement, 2, modelBytes, modelBytes.Length, Transient) != Ok ||
                sqlite3_bind_text(statement, 3, effortBytes, effortBytes.Length, Transient) != Ok)
                throw new InvalidOperationException(Error(source));
            if (sqlite3_step(statement) != Done) throw new InvalidOperationException(Error(source));
            sqlite3_finalize(statement);
            statement = IntPtr.Zero;
            Exec(source, "COMMIT");
            transaction = false;
            CheckSchema(source);
            return count;
        }
        catch
        {
            if (transaction && source != IntPtr.Zero)
            {
                try { Exec(source, "ROLLBACK"); } catch { }
            }
            throw;
        }
        finally
        {
            if (statement != IntPtr.Zero) sqlite3_finalize(statement);
            if (destination != IntPtr.Zero) sqlite3_close_v2(destination);
            if (source != IntPtr.Zero) sqlite3_close_v2(source);
        }
    }

    public static long RestoreSkippedRoutes(string path, string backup, string[] paths, string[] ids)
    {
        IntPtr db = Open(path, ReadWrite);
        try
        {
            Exec(db, "ATTACH DATABASE '" + backup.Replace("'", "''") + "' AS switcher_original");
            Exec(db, "BEGIN IMMEDIATE");
            long restored = 0;
            for (int i = 0; i < paths.Length; i++)
            {
                string originalPath = paths[i].Replace('\\', '/').Replace("'", "''");
                string id = i < ids.Length ? ids[i] : "";
                string condition = "replace(rollout_path, char(92), '/')='" + originalPath + "'";
                if (!string.IsNullOrEmpty(id)) condition += " OR id='" + id.Replace("'", "''") + "'";
                // Relative rollout paths also occur in older databases.
                int session = originalPath.IndexOf("/sessions/", StringComparison.OrdinalIgnoreCase);
                if (session < 0) session = originalPath.IndexOf("/archived_sessions/", StringComparison.OrdinalIgnoreCase);
                if (session >= 0) condition += " OR replace(rollout_path, char(92), '/')='" + originalPath.Substring(session + 1) + "'";
                restored += ScalarInt64(db, "SELECT count(*) FROM threads WHERE " + condition);
                Exec(db, "UPDATE threads SET model_provider=(SELECT b.model_provider FROM switcher_original.threads b WHERE b.id=threads.id),"
                    + " model=(SELECT b.model FROM switcher_original.threads b WHERE b.id=threads.id),"
                    + " reasoning_effort=(SELECT b.reasoning_effort FROM switcher_original.threads b WHERE b.id=threads.id) WHERE " + condition);
            }
            Exec(db, "COMMIT");
            return restored;
        }
        catch { try { Exec(db, "ROLLBACK"); } catch { } throw; }
        finally { sqlite3_close_v2(db); }
    }

    public static bool HasProjectionTables(string path)
    {
        IntPtr db = IntPtr.Zero;
        try
        {
            db = Open(path, ReadOnly);
            return TableExists(db, "thread_history_projection_state") &&
                TableExists(db, "thread_items") && TableExists(db, "thread_turns");
        }
        catch { return false; }
        finally { if (db != IntPtr.Zero) sqlite3_close_v2(db); }
    }

    public static long BackupAndClearProjection(string databasePath, string backupPath)
    {
        IntPtr source = IntPtr.Zero;
        IntPtr destination = IntPtr.Zero;
        bool transaction = false;
        try
        {
            source = Open(databasePath, ReadWrite);
            Exec(source, "PRAGMA busy_timeout=5000");
            CheckIntegrity(source);
            destination = Open(backupPath, ReadWrite | Create);
            CopyDatabase(source, destination);
            sqlite3_close_v2(destination);
            destination = IntPtr.Zero;
            Exec(source, "BEGIN IMMEDIATE");
            transaction = true;
            long count = 0;
            foreach (string table in new[] { "thread_items", "thread_turns", "thread_history_projection_state", "thread_realtime_items" })
            {
                if (!TableExists(source, table)) continue;
                count += ScalarInt64(source, "SELECT COUNT(*) FROM \"" + table + "\"");
                Exec(source, "DELETE FROM \"" + table + "\"");
            }
            Exec(source, "COMMIT");
            transaction = false;
            CheckIntegrity(source);
            return count;
        }
        catch
        {
            if (transaction && source != IntPtr.Zero)
            {
                try { Exec(source, "ROLLBACK"); } catch { }
            }
            throw;
        }
        finally
        {
            if (destination != IntPtr.Zero) sqlite3_close_v2(destination);
            if (source != IntPtr.Zero) sqlite3_close_v2(source);
        }
    }

    public static void Restore(string backupPath, string databasePath)
    {
        IntPtr source = IntPtr.Zero;
        IntPtr destination = IntPtr.Zero;
        try
        {
            source = Open(backupPath, ReadOnly);
            destination = Open(databasePath, ReadWrite);
            CheckIntegrity(source);
            Exec(destination, "PRAGMA busy_timeout=5000");
            CopyDatabase(source, destination);
            CheckIntegrity(destination);
        }
        finally
        {
            if (destination != IntPtr.Zero) sqlite3_close_v2(destination);
            if (source != IntPtr.Zero) sqlite3_close_v2(source);
        }
    }
}

// Also serves as the result object: TempPath points at the rewritten copy, and Changed
// says whether it differs from the source file.
public sealed class CodexSwitcherRolloutStats
{
    public int Lines;
    public int ChangedLines;
    public int RouteChanges;
    public int CompatibilityChanges;
    public string TempPath;
    public bool Changed;
}

public sealed class CodexSwitcherRolloutFormatException : Exception
{
    public readonly string FilePath;
    public readonly int LineNumber;

    public CodexSwitcherRolloutFormatException(string filePath, int lineNumber, Exception inner)
        : base(inner == null ? "invalid JSON" : inner.Message, inner)
    {
        FilePath = filePath;
        LineNumber = lineNumber;
    }
}

// Fast, dependency-free rollout rewriter. Reads a rollout JSONL, applies the current
// provider/model routing fields plus cross-provider compatibility fixes, and writes the
// result back. Lines that need no change are copied byte for byte.
public static class CodexSwitcherRollout
{
    const int KindScalar = 0;
    const int KindObject = 1;
    const int KindArray = 2;
    const int MaxDepth = 400;

    sealed class Node
    {
        public int Kind;
        public string Raw;               // scalar: exact source text
        public string Text;              // scalar: decoded value for JSON strings, null otherwise
        public List<string> Keys;        // object: decoded keys
        public List<string> KeyRaw;      // object: raw key tokens including quotes
        public List<Node> Values;        // object values or array items
    }

    sealed class Parser
    {
        readonly string Source;
        int Index;
        int Depth;

        public Parser(string source) { Source = source; Index = 0; Depth = 0; }

        public Node ParseDocument()
        {
            SkipWhitespace();
            Node node = ParseValue();
            SkipWhitespace();
            if (Index != Source.Length) throw new FormatException("trailing content after JSON value");
            return node;
        }

        void SkipWhitespace()
        {
            while (Index < Source.Length)
            {
                char c = Source[Index];
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') Index++;
                else break;
            }
        }

        Node ParseValue()
        {
            if (Index >= Source.Length) throw new FormatException("unexpected end of JSON");
            char c = Source[Index];
            if (c == '{') return ParseObject();
            if (c == '[') return ParseArray();
            if (c == '"') return ParseString();
            return ParseLiteral();
        }

        Node ParseObject()
        {
            if (++Depth > MaxDepth) throw new FormatException("JSON nesting too deep");
            Node node = new Node();
            node.Kind = KindObject;
            node.Keys = new List<string>();
            node.KeyRaw = new List<string>();
            node.Values = new List<Node>();
            Index++; // '{'
            SkipWhitespace();
            if (Index < Source.Length && Source[Index] == '}') { Index++; Depth--; return node; }
            while (true)
            {
                SkipWhitespace();
                if (Index >= Source.Length || Source[Index] != '"') throw new FormatException("expected object key");
                Node key = ParseString();
                node.Keys.Add(key.Text);
                node.KeyRaw.Add(key.Raw);
                SkipWhitespace();
                if (Index >= Source.Length || Source[Index] != ':') throw new FormatException("expected ':'");
                Index++;
                SkipWhitespace();
                node.Values.Add(ParseValue());
                SkipWhitespace();
                if (Index >= Source.Length) throw new FormatException("unterminated object");
                if (Source[Index] == ',') { Index++; continue; }
                if (Source[Index] == '}') { Index++; break; }
                throw new FormatException("expected ',' or '}'");
            }
            Depth--;
            return node;
        }

        Node ParseArray()
        {
            if (++Depth > MaxDepth) throw new FormatException("JSON nesting too deep");
            Node node = new Node();
            node.Kind = KindArray;
            node.Values = new List<Node>();
            Index++; // '['
            SkipWhitespace();
            if (Index < Source.Length && Source[Index] == ']') { Index++; Depth--; return node; }
            while (true)
            {
                SkipWhitespace();
                node.Values.Add(ParseValue());
                SkipWhitespace();
                if (Index >= Source.Length) throw new FormatException("unterminated array");
                if (Source[Index] == ',') { Index++; continue; }
                if (Source[Index] == ']') { Index++; break; }
                throw new FormatException("expected ',' or ']'");
            }
            Depth--;
            return node;
        }

        Node ParseString()
        {
            int start = Index;
            Index++; // opening quote
            StringBuilder text = new StringBuilder();
            while (true)
            {
                if (Index >= Source.Length) throw new FormatException("unterminated string");
                char c = Source[Index];
                if (c == '"') { Index++; break; }
                if (c == '\\')
                {
                    Index++;
                    if (Index >= Source.Length) throw new FormatException("unterminated escape");
                    char e = Source[Index];
                    switch (e)
                    {
                        case '"': text.Append('"'); Index++; break;
                        case '\\': text.Append('\\'); Index++; break;
                        case '/': text.Append('/'); Index++; break;
                        case 'b': text.Append('\b'); Index++; break;
                        case 'f': text.Append('\f'); Index++; break;
                        case 'n': text.Append('\n'); Index++; break;
                        case 'r': text.Append('\r'); Index++; break;
                        case 't': text.Append('\t'); Index++; break;
                        case 'u':
                            if (Index + 4 >= Source.Length) throw new FormatException("bad unicode escape");
                            text.Append((char)Convert.ToInt32(Source.Substring(Index + 1, 4), 16));
                            Index += 5;
                            break;
                        default: throw new FormatException("bad escape sequence");
                    }
                    continue;
                }
                text.Append(c);
                Index++;
            }
            Node node = new Node();
            node.Kind = KindScalar;
            node.Text = text.ToString();
            node.Raw = Source.Substring(start, Index - start);
            return node;
        }

        Node ParseLiteral()
        {
            int start = Index;
            while (Index < Source.Length)
            {
                char c = Source[Index];
                if (c == ',' || c == '}' || c == ']' || c == ' ' || c == '\t' || c == '\r' || c == '\n') break;
                Index++;
            }
            if (Index == start) throw new FormatException("unexpected character");
            string raw = Source.Substring(start, Index - start);
            if (raw != "true" && raw != "false" && raw != "null" && !IsNumber(raw))
                throw new FormatException("invalid literal");
            Node node = new Node();
            node.Kind = KindScalar;
            node.Raw = raw;
            node.Text = null;
            return node;
        }
    }

    // Accepts JSON's number grammar without depending on the host's floating point parsing.
    static bool IsNumber(string raw)
    {
        int i = 0;
        if (i < raw.Length && raw[i] == '-') i++;
        int digits = 0;
        while (i < raw.Length && raw[i] >= '0' && raw[i] <= '9') { i++; digits++; }
        if (digits == 0) return false;
        if (i < raw.Length && raw[i] == '.')
        {
            i++;
            int fraction = 0;
            while (i < raw.Length && raw[i] >= '0' && raw[i] <= '9') { i++; fraction++; }
            if (fraction == 0) return false;
        }
        if (i < raw.Length && (raw[i] == 'e' || raw[i] == 'E'))
        {
            i++;
            if (i < raw.Length && (raw[i] == '+' || raw[i] == '-')) i++;
            int exponent = 0;
            while (i < raw.Length && raw[i] >= '0' && raw[i] <= '9') { i++; exponent++; }
            if (exponent == 0) return false;
        }
        return i == raw.Length;
    }

    static string Quote(string value)
    {
        StringBuilder sb = new StringBuilder(value.Length + 2);
        sb.Append('"');
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '"') sb.Append("\\\"");
            else if (c == '\\') sb.Append("\\\\");
            else if (c == '\b') sb.Append("\\b");
            else if (c == '\f') sb.Append("\\f");
            else if (c == '\n') sb.Append("\\n");
            else if (c == '\r') sb.Append("\\r");
            else if (c == '\t') sb.Append("\\t");
            else if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4", System.Globalization.CultureInfo.InvariantCulture));
            else sb.Append(c);
        }
        sb.Append('"');
        return sb.ToString();
    }

    static Node NewString(string value)
    {
        Node node = new Node();
        node.Kind = KindScalar;
        node.Text = value;
        node.Raw = Quote(value);
        return node;
    }

    static Node NewNull()
    {
        Node node = new Node();
        node.Kind = KindScalar;
        node.Text = null;
        node.Raw = "null";
        return node;
    }

    static Node NewEmptyArray()
    {
        Node node = new Node();
        node.Kind = KindArray;
        node.Values = new List<Node>();
        return node;
    }

    static void Serialize(Node node, StringBuilder sb)
    {
        if (node == null) { sb.Append("null"); return; }
        if (node.Kind == KindScalar) { sb.Append(node.Raw == null ? "null" : node.Raw); return; }
        if (node.Kind == KindArray)
        {
            sb.Append('[');
            for (int i = 0; i < node.Values.Count; i++)
            {
                if (i > 0) sb.Append(',');
                Serialize(node.Values[i], sb);
            }
            sb.Append(']');
            return;
        }
        sb.Append('{');
        for (int i = 0; i < node.Values.Count; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append(node.KeyRaw[i]);
            sb.Append(':');
            Serialize(node.Values[i], sb);
        }
        sb.Append('}');
    }

    static int IndexOfKey(Node node, string key)
    {
        if (node == null || node.Kind != KindObject) return -1;
        for (int i = 0; i < node.Keys.Count; i++)
        {
            if (string.Equals(node.Keys[i], key, StringComparison.Ordinal)) return i;
        }
        return -1;
    }

    static Node Child(Node node, string key)
    {
        int index = IndexOfKey(node, key);
        if (index < 0) return null;
        return node.Values[index];
    }

    static string ScalarText(Node node)
    {
        if (node == null || node.Kind != KindScalar) return null;
        return node.Text;
    }

    static void SetExistingString(Node node, string key, string value, CodexSwitcherRolloutStats stats)
    {
        int index = IndexOfKey(node, key);
        if (index < 0) return;
        Node current = node.Values[index];
        string text = ScalarText(current);
        if (text != null && string.Equals(text, value, StringComparison.Ordinal)) return;
        node.Values[index] = NewString(value);
        stats.RouteChanges++;
    }

    static void SetExistingNull(Node node, string key, CodexSwitcherRolloutStats stats)
    {
        int index = IndexOfKey(node, key);
        if (index < 0) return;
        Node current = node.Values[index];
        if (current != null && current.Kind == KindScalar && current.Raw == "null") return;
        node.Values[index] = NewNull();
        stats.RouteChanges++;
    }

    static void RemoveKey(Node node, string key, CodexSwitcherRolloutStats stats)
    {
        int index = IndexOfKey(node, key);
        if (index < 0) return;
        node.Keys.RemoveAt(index);
        node.KeyRaw.RemoveAt(index);
        node.Values.RemoveAt(index);
        stats.CompatibilityChanges++;
    }

    static readonly string[] ToolTypes = new string[]
    {
        "function_call", "function_call_output", "custom_tool_call",
        "custom_tool_call_output", "tool_search_call", "tool_search_output"
    };

    static bool IsToolType(string value)
    {
        if (value == null) return false;
        for (int i = 0; i < ToolTypes.Length; i++)
        {
            if (string.Equals(ToolTypes[i], value, StringComparison.Ordinal)) return true;
        }
        return false;
    }

    static void WalkCompatible(Node node, string provider, CodexSwitcherRolloutStats stats, Dictionary<string, string> toolIds)
    {
        if (node == null || node.Kind == KindScalar) return;
        string itemType = ScalarText(Child(node, "type"));
        if (node.Kind == KindObject && string.Equals(itemType, "reasoning", StringComparison.OrdinalIgnoreCase))
        {
            RemoveKey(node, "encrypted_content", stats);
            RemoveKey(node, "id", stats);
            int contentIndex = IndexOfKey(node, "content");
            if (contentIndex >= 0 && string.Equals(provider, "openai", StringComparison.OrdinalIgnoreCase))
            {
                Node content = node.Values[contentIndex];
                if (content != null && content.Kind == KindArray && content.Values.Count > 0)
                {
                    node.Values[contentIndex] = NewEmptyArray();
                    stats.CompatibilityChanges++;
                }
            }
        }
        if (node.Kind == KindObject && IsToolType(itemType))
        {
            ConvertToolId(node, "call_id", stats, toolIds);
            ConvertToolId(node, "id", stats, toolIds);
        }
        List<Node> values = node.Values;
        if (values == null) return;
        for (int i = 0; i < values.Count; i++) WalkCompatible(values[i], provider, stats, toolIds);
    }

    static void ConvertToolId(Node node, string key, CodexSwitcherRolloutStats stats, Dictionary<string, string> toolIds)
    {
        int index = IndexOfKey(node, key);
        if (index < 0) return;
        Node current = node.Values[index];
        string text = ScalarText(current);
        if (text == null || !text.StartsWith("tool_", StringComparison.Ordinal)) return;
        string replacement;
        if (!toolIds.TryGetValue(text, out replacement))
        {
            replacement = "fc_" + text.Substring(5);
            toolIds[text] = replacement;
        }
        node.Values[index] = NewString(replacement);
        stats.CompatibilityChanges++;
    }

    static void ApplyRouting(Node record, string provider, string model, string effort, CodexSwitcherRolloutStats stats)
    {
        string recordType = ScalarText(Child(record, "type"));
        if (recordType == null) return;
        Node payload = Child(record, "payload");
        if (payload == null) return;

        if (string.Equals(recordType, "session_meta", StringComparison.OrdinalIgnoreCase))
        {
            SetExistingString(payload, "model_provider", provider, stats);
            return;
        }
        if (string.Equals(recordType, "turn_context", StringComparison.OrdinalIgnoreCase))
        {
            SetExistingString(payload, "model", model, stats);
            SetExistingString(payload, "effort", effort, stats);
            Node settings = Child(Child(payload, "collaboration_mode"), "settings");
            SetExistingString(settings, "model", model, stats);
            SetExistingString(settings, "reasoning_effort", effort, stats);
            return;
        }
        if (string.Equals(recordType, "event_msg", StringComparison.OrdinalIgnoreCase))
        {
            if (!string.Equals(ScalarText(Child(payload, "type")), "thread_settings_applied", StringComparison.OrdinalIgnoreCase)) return;
            Node threadSettings = Child(payload, "thread_settings");
            if (threadSettings == null) return;
            SetExistingString(threadSettings, "model", model, stats);
            SetExistingString(threadSettings, "model_provider_id", provider, stats);
            SetExistingString(threadSettings, "reasoning_effort", effort, stats);
            if (string.Equals(provider, "deepseek", StringComparison.OrdinalIgnoreCase)) SetExistingNull(threadSettings, "service_tier", stats);
            Node settings = Child(Child(threadSettings, "collaboration_mode"), "settings");
            SetExistingString(settings, "model", model, stats);
            SetExistingString(settings, "reasoning_effort", effort, stats);
            return;
        }
        if (string.Equals(recordType, "world_state", StringComparison.OrdinalIgnoreCase))
        {
            Node state = Child(payload, "state");
            if (state == null) return;
            SetExistingString(state, "model", model, stats);
            Node collaboration = Child(state, "collaboration_mode");
            SetExistingString(collaboration, "model", model, stats);
            Node personality = Child(state, "personality");
            SetExistingString(personality, "model", model, stats);
            return;
        }
        if (string.Equals(recordType, "compacted", StringComparison.OrdinalIgnoreCase))
        {
            Node previous = Child(Child(payload, "resume_metadata"), "previous_turn_settings");
            if (previous == null) return;
            SetExistingString(previous, "model", model, stats);
            SetExistingString(previous, "model_provider_id", provider, stats);
            SetExistingString(previous, "reasoning_effort", effort, stats);
            return;
        }
    }

    static void DetectLayout(string path, out string newline, out bool trailing)
    {
        newline = "\n";
        trailing = false;
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            byte[] buffer = new byte[65536];
            int read = stream.Read(buffer, 0, buffer.Length);
            for (int i = 0; i < read; i++)
            {
                if (buffer[i] == 10)
                {
                    if (i > 0 && buffer[i - 1] == 13) newline = "\r\n";
                    break;
                }
            }
            if (stream.Length > 0)
            {
                stream.Seek(-1, SeekOrigin.End);
                trailing = stream.ReadByte() == 10;
            }
        }
    }

    // Returns the byte offset of the first line whose root-level "ordinal" equals the target.
    public static long FindOrdinalOffset(string path, long ordinal)
    {
        string newline;
        bool trailing;
        DetectLayout(path, out newline, out trailing);
        UTF8Encoding utf8 = new UTF8Encoding(false);
        int newlineBytes = utf8.GetByteCount(newline);
        long offset = 0;
        using (FileStream handle = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (StreamReader reader = new StreamReader(handle, utf8, true, 65536))
        {
            string line;
            while ((line = reader.ReadLine()) != null)
            {
                Node record = null;
                try { record = new Parser(line).ParseDocument(); }
                catch (FormatException) { record = null; }
                if (record != null)
                {
                    Node ordinalNode = Child(record, "ordinal");
                    string raw = ordinalNode == null ? null : ordinalNode.Raw;
                    if (raw != null)
                    {
                        long value;
                        if (long.TryParse(raw, out value) && value == ordinal) return offset;
                    }
                }
                offset += utf8.GetByteCount(line) + newlineBytes;
            }
        }
        return -1;
    }

    public static CodexSwitcherRolloutStats RewriteFile(string path, string provider, string model, string effort)
    {
        string newline;
        bool trailing;
        DetectLayout(path, out newline, out trailing);
        UTF8Encoding utf8 = new UTF8Encoding(false);
        CodexSwitcherRolloutStats stats = new CodexSwitcherRolloutStats();
        Dictionary<string, string> toolIds = new Dictionary<string, string>(StringComparer.Ordinal);
        string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        bool wroteAny = false;
        stats.TempPath = temp;
        try
        {
            using (FileStream handle = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (StreamReader reader = new StreamReader(handle, utf8, true, 65536))
            using (StreamWriter writer = new StreamWriter(temp, false, utf8, 65536))
            {
                bool first = true;
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    stats.Lines++;
                    Node record;
                    try { record = new Parser(line).ParseDocument(); }
                    catch (FormatException error) { throw new CodexSwitcherRolloutFormatException(path, stats.Lines, error); }

                    if (stats.Lines == 1)
                    {
                        string headerType = ScalarText(Child(record, "type"));
                        Node payload = Child(record, "payload");
                        if (!string.Equals(headerType, "session_meta", StringComparison.OrdinalIgnoreCase) || payload == null || IndexOfKey(payload, "model_provider") < 0)
                        {
                            throw new CodexSwitcherRolloutFormatException(path, 1, new FormatException("missing session_meta.model_provider"));
                        }
                    }

                    int before = stats.RouteChanges + stats.CompatibilityChanges;
                    ApplyRouting(record, provider, model, effort, stats);
                    WalkCompatible(record, provider, stats, toolIds);
                    string output = line;
                    if (stats.RouteChanges + stats.CompatibilityChanges != before)
                    {
                        StringBuilder sb = new StringBuilder(line.Length + 256);
                        Serialize(record, sb);
                        output = sb.ToString();
                        stats.ChangedLines++;
                    }
                    if (!first) writer.Write(newline);
                    first = false;
                    writer.Write(output);
                    wroteAny = true;
                }
                if (trailing && wroteAny) writer.Write(newline);
            }
            stats.Changed = stats.ChangedLines > 0;
            return stats;
        }
        catch
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { }
            throw;
        }
    }
}
