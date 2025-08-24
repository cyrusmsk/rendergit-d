module rendergit;

import std.stdio : writeln, File;
import std.path : buildNormalizedPath, asRelativePath, asAbsolutePath, extension, stripExtension, setExtension;
import std.file : SpanMode, dirEntries, getSize, mkdir, rmdirRecurse, tempDir, FileException, read, readText, write;
import std.conv : to, text;
import std.algorithm : map, canFind, filter, sort, sum;
import std.string : isNumeric, empty, strip, split, stripRight, startsWith;
import std.uni : toLower, isAlphaNum;
import std.process : browse, execute, Config, ProcessException;
import std.array : join, array, appender;
import std.utf : UTFException, validate, byUTF, UseReplacementDchar;
import std.format : format;

// External dependencies
import commandr;
import commonmarkd;


enum MAX_BYTES = 50 * 1024;
static immutable BINARY_EXTENSIONS = [
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg", ".ico",
    ".pdf", ".zip", ".tar", ".gz", ".bz2", ".xz", ".7z", ".rar",
    ".mp3", ".mp4", ".mov", ".avi", ".mkv", ".wav", ".ogg", ".flac",
    ".ttf", ".otf", ".eot", ".woff", ".woff2",
    ".so", ".dll", ".dylib", ".class", ".jar", ".exe", ".bin",
];
static immutable MARKDOWN_EXTENSIONS = [".md", ".markdown", ".mdown", ".mkd", ".mkdn"];

enum Reason {
    ok,
    binary,
    tooLargege,
    ignored
}

struct RenderDecision {
    bool include;
    Reason reason;
}

struct FileInfo {
    string absPath;
    string relPath;
    ulong fileSize;
    RenderDecision decision;
}

string run(string[] cmd, string cwd = null, bool check = false) {
    auto cmdResult = execute(cmd, workDir: cwd);
    if (check)
        if (cmdResult.status != 0)
            throw new ProcessException("Command failed with exit code " ~ cmdResult.status.to!string);
    return cmdResult.output;
}

void gitClone(string url, string dst) {
    try {
        run(["git", "clone", "--depth", "1", url, dst]);
    }
    catch (ProcessException pe) {
        writeln("While running gitClone process exception catched: ", pe);
    }
}

string gitHeadCommit(string repoDir) {
    try {
        auto result = run(["git", "rev-parse", "HEAD"], cwd: repoDir);
        return result.strip();
    }
    catch (ProcessException pe) {
        writeln("While running gitClone process exception catched: ", pe);
        return "(unknown)";
    }
}

string bytesHuman(ulong n) {
    immutable static units = ["B", "KiB", "MiB", "GiB", "TiB"];
    float f = n * 1.0f;
    uint i = 0;
    while (f >= 1024.0 && i <= units.length) {
        f /= 1024.0;
        i++;
    }
    if (i == 0)
        return format("%d %s", cast(int)f, units[i]);
    else
        return format("%.1f %s", f, units[i]);
}

bool looksBinary(string path) {
    string ext = path.extension.toLower();
    if (canFind(BINARY_EXTENSIONS, ext))
        return true;
    try {
        ubyte[] chunk;
        try
            chunk = cast(ubyte[]) File(path, "rb").byChunk(8_192).front;
        catch (Exception)
            return true;
        if (chunk.canFind(0))
            return true;
        try
            validate(cast(string) chunk);
        catch (UTFException)
            return true;

        return false;
    }
    catch (Exception)
        return true;
}

FileInfo decideFile(string path, string repoRoot, ulong maxBytes) {
    string rel = buildNormalizedPath(asRelativePath(path, repoRoot).to!string);
    ulong fileSize;
    try
        fileSize = path.getSize();
    catch (FileException fe)
        fileSize = 0;
    if (rel.startsWith(".git/") || canFind("/.git/", rel))
        return FileInfo(path, rel, fileSize, RenderDecision(false, Reason.ignored));
    else if (fileSize > maxBytes)
        return FileInfo(path, rel, fileSize, RenderDecision(false, Reason.tooLargege));
    else if (looksBinary(path))
        return FileInfo(path, rel, fileSize, RenderDecision(false, Reason.binary));
    return FileInfo(path, rel, fileSize, RenderDecision(true, Reason.ok));
}

FileInfo[] collectFiles(string repoRoot, ulong maxBytes) {
    FileInfo[] infos;
    auto app = appender(&infos);

    foreach (p; dirEntries(repoRoot, SpanMode.depth, false)
        .filter!(e => !e.isSymlink).array.sort())
        if (p.isFile)
            app ~= decideFile(p.name, repoRoot, maxBytes);
    return infos;
}

string generateTreeFallback(string root) {
    string[] lines;
    auto app = appender(&lines);

    void walk(string dirPath, string prefix = "") {
        auto entries = dirEntries(dirPath, SpanMode.shallow, false)
            .filter!(e => e.name != ".git")
            .array
            .sort!((a, b) => a.isDir != b.isDir ? a.isDir > b.isDir : a.name.toLower < b.name.toLower
                //(cast(bool)!a.isDir, a.name.toLower) <
                //(cast(bool)!b.isDir, b.name.toLower)
            ).array;

        int latestIndex = cast(int) entries.length - 1;
        foreach (i, e; entries) {
            bool last = i == latestIndex;
            string branch = last ? "└── " : "├── ";
            app ~= prefix ~ branch ~ e.name;
            if (e.isDir) {
                string ext = last ? "    " : "│   ";
                walk(e, prefix ~ ext);
            }
        }
    }
    app ~= root;
    walk(root);

    return lines.join("\n").array.to!string;
}

string tryTreeCommand(string root) {
    try {
        auto res = run(["tree", "-a", "."], cwd : root);
        return res;
    }
    catch (Exception e)
        return generateTreeFallback(root);
}

string safeReadText(string path)
{
    string content;
    try
        content = readText(path);
    catch (UTFException ue)
    {
        ubyte[] bytes = cast(ubyte[]) read(path);
        content = bytes.to!string;
    }
    return content;
}

string renderMarkdownText(string mdText) {
    return convertMarkdownToHTML(mdText, MarkdownFlag.dialectGitHub);
}

string highlightCode(string text, string filename) {
    // TODO: choose dependency chroma or highlight from Andre Simon
    return text;
}

string slugify(string pathStr) {
    auto o = appender!string;
    foreach(dchar ch; pathStr)
        if (ch.isAlphaNum || ch == '-' || ch == '_')
            o ~= ch;
        else
            o ~= '-';
    return o.data;
}

string generateCxmlText(FileInfo[] infos) {
    string[] lines = ["<documents>"];
    auto app = appender(&lines);
    auto rendered = infos.filter!(e => e.decision.include);
    int index = 1;
    foreach(i; rendered) {
        app ~= text("<document index=",index,">");
        app ~= text("<source>",i.relPath,"</source>");
        app ~= "<document_content>";
        try {
            auto txt = safeReadText(i.absPath);
            app ~= txt;
        }
        catch (Exception e)
            app ~= text("Failed to read: ", e.msg);
        app ~= "</document_content>";
        app ~= "</document>";
    }
    app ~= "</documents>";

    return lines.join("\n");
}

string buildHtml(string repoUrl, string repoDir, string headCommit, ref FileInfo[] infos) {
    string htmlEscape(string input)
    {
        auto w = appender!string;
        foreach (c; input)
        {
            switch (c)
            {
                case '&':  w ~= "&amp;";   break;
                case '<':  w ~= "&lt;";    break;
                case '>':  w ~= "&gt;";    break;
                case '"':  w ~= "&quot;";  break;
                case '\'': w ~= "&#x27;";  break;
                default:   w ~= c;         break;
            }
        }
        return w.data;
    }

    // stats
    FileInfo*[] rendered;
    FileInfo*[] skippedBinary;
    FileInfo*[] skippedLarge;
    FileInfo*[] skippedIgnored;
    foreach(ref i; infos) {
        if (i.decision.include)
            rendered ~= &i;
        else if (i.decision.reason == Reason.binary)
        skippedBinary ~= &i;
        else if (i.decision.reason == Reason.tooLargege)
        skippedLarge ~= &i;
        else if (i.decision.reason == Reason.ignored)
        skippedIgnored ~= &i;
    }
    ulong totalFiles1 = infos.length;
    ulong totalFiles2 = rendered.length + skippedBinary.length + skippedIgnored.length + skippedLarge.length;
    writeln("Comparison totalFiles1: ", totalFiles1, " totalFiles2: ", totalFiles2);

    // Directory tree
    auto treeText = tryTreeCommand(repoDir);

    // Generate CXML text for LLM view
    auto cxmlText = generateCxmlText(infos);

    // Table of contents
    string[] tocItems;
    string[] sections;

    auto appToc = appender(&tocItems);
    auto appSec = appender(&sections);

    // Render file sections
    foreach(i; rendered) {
        auto anchor = slugify(i.relPath);
        appToc ~= text(
            `<li><a href="#file-`,anchor,`">`,htmlEscape(i.relPath),`</a> `,
            `<span class="muted">(`, bytesHuman(i.fileSize),`)</span></li>`
        );

        string bodyHtml;
        auto p = i.absPath;
        auto ext = p.extension.toLower();
        try {
            auto txt = safeReadText(p);
            if (canFind(MARKDOWN_EXTENSIONS, ext))
                bodyHtml = renderMarkdownText(txt);
            else {
                bodyHtml = text(`<div class="highlight">`, highlightCode(txt, i.relPath),`</div>`);
            }
        }
        catch (Exception e) {
            bodyHtml = text(`<pre class="errpr"> Failed to render :`, htmlEscape(e.msg), `</pre>`);
        }
        appSec ~= i`
        <section class="file-section" id="file-$(anchor)">
          <h2>$(htmlEscape(i.relPath)) <span class="muted">($(bytesHuman(i.fileSize)))</span></h2>
          <div class="file-body">$(bodyHtml)</div>
          <div class="back-top"><a href="#top">↑ Back to top</a></div>
        </section>
        `.text;
    }
    auto tocHtml = tocItems.join("");

    // Skip lists
    string renderSkipList(string title, FileInfo*[] items) {
        if (infos == null)
            return "";
        string[] lis;
        auto app = appender(&lis);
        foreach(i; items)
            app ~= text(
                `<li><code>`, htmlEscape(i.relPath), `</code> `,
                `<span clas="muted">(`,bytesHuman(i.fileSize),`)</span></li>`
            );
        return text(
            "<details open><summary>", htmlEscape(title), " (", items.length, ")</summary>",
            "<ul class='skip-list'>\n", lis.join("\n"), "\n</ul></details>"
        );
    }

    string skippedHtml =
        renderSkipList("Skipped binaries", skippedBinary) ~
        renderSkipList("Skipped large files", skippedLarge);

    return i`
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Flattened repo – $(htmlEscape(repoUrl))</title>
    <style>
      body {{
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, 'Apple Color Emoji','Segoe UI Emoji';
        margin: 0; padding: 0; line-height: 1.45;
      }}
      .container {{ max-width: 1100px; margin: 0 auto; padding: 0 1rem; }}
      .meta small {{ color: #666; }}
      .counts {{ margin-top: 0.25rem; color: #333; }}
      .muted {{ color: #777; font-weight: normal; font-size: 0.9em; }}

      /* Layout with sidebar */
      .page {{ display: grid; grid-template-columns: 320px minmax(0,1fr); gap: 0; }}
      #sidebar {{
        position: sticky; top: 0; align-self: start;
        height: 100vh; overflow: auto;
        border-right: 1px solid #eee; background: #fafbfc;
      }}
      #sidebar .sidebar-inner {{ padding: 0.75rem; }}
      #sidebar h2 {{ margin: 0 0 0.5rem 0; font-size: 1rem; }}

      .toc {{ list-style: none; padding-left: 0; margin: 0; overflow-x: auto; }}
      .toc li {{ padding: 0.15rem 0; white-space: nowrap; }}
      .toc a {{ text-decoration: none; color: #0366d6; display: inline-block; text-decoration: none; }}
      .toc a:hover {{ text-decoration: underline; }}

      main.container {{ padding-top: 1rem; }}

      pre {{ background: #f6f8fa; padding: 0.75rem; overflow: auto; border-radius: 6px; }}
      code {{ font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono','Courier New', monospace; }}
      .highlight {{ overflow-x: auto; }}
      .file-section {{ padding: 1rem; border-top: 1px solid #eee; }}
      .file-section h2 {{ margin: 0 0 0.5rem 0; font-size: 1.1rem; }}
      .file-body {{ margin-bottom: 0.5rem; }}
      .back-top {{ font-size: 0.9rem; }}
      .skip-list code {{ background: #f6f8fa; padding: 0.1rem 0.3rem; border-radius: 4px; }}
      .error {{ color: #b00020; background: #fff3f3; }}

      /* Hide duplicate top TOC on wide screens */
      .toc-top {{ display: block; }}
      @media (min-width: 1000px) {{ .toc-top {{ display: none; }} }}

      :target {{ scroll-margin-top: 8px; }}

      /* View toggle */
      .view-toggle {{
        margin: 1rem 0;
        display: flex;
        gap: 0.5rem;
        align-items: center;
      }}
      .toggle-btn {{
        padding: 0.5rem 1rem;
        border: 1px solid #d1d9e0;
        background: white;
        cursor: pointer;
        border-radius: 6px;
        font-size: 0.9rem;
      }}
      .toggle-btn.active {{
        background: #0366d6;
        color: white;
        border-color: #0366d6;
      }}
      .toggle-btn:hover:not(.active) {{
        background: #f6f8fa;
      }}

      /* LLM view */
      #llm-view {{ display: none; }}
      #llm-text {{
        width: 100%;
        height: 70vh;
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
        font-size: 0.85em;
        border: 1px solid #d1d9e0;
        border-radius: 6px;
        padding: 1rem;
        resize: vertical;
      }}
      .copy-hint {{
        margin-top: 0.5rem;
        color: #666;
        font-size: 0.9em;
      }}

    </style>
    </head>
    <body>
    <a id="top"></a>

    <div class="page">
      <nav id="sidebar"><div class="sidebar-inner">
          <h2>Contents ($(rendered.length))</h2>
          <ul class="toc toc-sidebar">
            <li><a href="#top">↑ Back to top</a></li>
            $(tocHtml)
          </ul>
      </div></nav>

      <main class="container">

        <section>
            <div class="meta">
            <div><strong>Repository:</strong> <a href="$(htmlEscape(repoUrl))">$(htmlEscape(repoUrl))</a></div>
            <small><strong>HEAD commit:</strong> $(htmlEscape(headCommit))</small>
            <div class="counts">
                <strong>Total files:</strong> $(totalFiles1) · <strong>Rendered:</strong> $(rendered.length) · <strong>Skipped:</strong> $(skippedBinary.length + skippedLarge.length + skippedIgnored.length)
            </div>
            </div>
        </section>

        <div class="view-toggle">
          <strong>View:</strong>
          <button class="toggle-btn active" onclick="showHumanView()">👤 Human</button>
          <button class="toggle-btn" onclick="showLLMView()">🤖 LLM</button>
        </div>

        <div id="human-view">
          <section>
            <h2>Directory tree</h2>
            <pre>$(htmlEscape(treeText))</pre>
          </section>

          <section class="toc-top">
            <h2>Table of contents ($(rendered.length))</h2>
            <ul class="toc">$(tocHtml)</ul>
          </section>

          <section>
            <h2>Skipped items</h2>
            $(skippedHtml)
          </section>

          $(sections.join(""))
        </div>

        <div id="llm-view">
          <section>
            <h2>🤖 LLM View - CXML Format</h2>
            <p>Copy the text below and paste it to an LLM for analysis:</p>
            <textarea id="llm-text" readonly>$(htmlEscape(cxmlText))</textarea>
            <div class="copy-hint">
              💡 <strong>Tip:</strong> Click in the text area and press Ctrl+A (Cmd+A on Mac) to select all, then Ctrl+C (Cmd+C) to copy.
            </div>
          </section>
        </div>
      </main>
    </div>

    <script>
    function showHumanView() {{
      document.getElementById('human-view').style.display = 'block';
      document.getElementById('llm-view').style.display = 'none';
      document.querySelectorAll('.toggle-btn').forEach(btn => btn.classList.remove('active'));
      event.target.classList.add('active');
    }}

    function showLLMView() {{
      document.getElementById('human-view').style.display = 'none';
      document.getElementById('llm-view').style.display = 'block';
      document.querySelectorAll('.toggle-btn').forEach(btn => btn.classList.remove('active'));
      event.target.classList.add('active');

      // Auto-select all text when switching to LLM view for easy copying
      setTimeout(() => {{
        const textArea = document.getElementById('llm-text');
        textArea.focus();
        textArea.select();
      }}, 100);
    }}
    </script>
    </body>
    </html>
    `.text;
}

string deriveTmpFolder(string repoUrl) {
    auto parts = repoUrl.stripRight("/").split("/");
    string filename;
    if (parts.length >= 2) {
        string repoName = parts[$ - 1];
        if (repoName.extension == ".git")
            repoName = repoName.stripExtension;
        filename = repoName.setExtension(".html");
    } else {
        filename = "repo.html";
    }
    return buildNormalizedPath(tempDir, filename);
}

void main(string[] args) {
    auto a = new Program("rendergit", "0.1")
          .summary("Flatten github repo")
          .author("Sergei Giniatulin @ cyrusmsk")
          .add(new Argument("repo_url", "Git repository").name("repoUrl"))
          .add(new Flag(null, "no-open", "Don't open the bworser").name("noOpen"))
          .add(new Option("o", "out", "Output folder").name("outputPath"))
          .add(new Option(null, "max-bytes", "Maximum file size in bytes").name("maxBytes"))
          .parse(args);

    string outputPath;
    bool noOpen = a.flag("noOpen");
    int maxBytes = 1024;
    string repoUrl = a.arg("repoUrl");

    if (a.option("outputPath").empty)
        outputPath = deriveTmpFolder(a.arg("repoUrl"));
    else
        outputPath = asAbsolutePath(a.option("outputPath")).array;

    if (a.option("maxBytes").isNumeric)
        maxBytes = a.option("maxBytes").to!int;

    auto repoDir = buildNormalizedPath(tempDir, "repo");
    scope(exit) {
        repoDir.rmdirRecurse;
    }

    try {
        writeln(i"📁 Cloning $(repoUrl) to temporary directory: $(repoDir)");
        gitClone(repoUrl, repoDir);
        auto head = gitHeadCommit(repoDir);
        writeln(i"✓ Clone complete (HEAD: $(head[0..8]))");

        writeln(i"📊 Scanning files in $(repoDir)...");
        auto infos = collectFiles(repoDir, maxBytes);
        auto renderedCount = infos.map!(e => e.decision.include).sum;
        auto skippedCount = infos.length - renderedCount;
        writeln(i"✓ Found $(infos.length) files total ($(renderedCount) will be rendered, $(skippedCount) skipped)");

        writeln(i"🔨 Generating HTML...");
        auto htmlOut = buildHtml(repoUrl, repoDir, head, infos);

        auto outPath = buildNormalizedPath(outputPath);
        writeln(i"💾 Writing HTML file: $(outPath)");
        write(outPath, htmlOut);
        auto fileSize = outPath.getSize();
        writeln(i"✓ Wrote $(bytesHuman(fileSize)) to $(outPath)");

        if (!noOpen) {
            writeln(i"🌐 Opening $(outPath) in browser...");
            browse(i"file://$(outPath)".text);
        }

        writeln(i"🗑️ Cleaning up temporary directory: $(repoDir)");
    }
    catch (Exception e) {
        writeln("Exception catched: ", e);
    }
}
