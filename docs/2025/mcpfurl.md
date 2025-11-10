---
date: 2025-11-10
icon: lucide/bot
title: Building mcpfurl
description: mcpfurl is an MCP Web Scraper in Go (with ChromeDriver and Selenium)
hide:
    - toc

---

# Building mcpfurl
> *mcpfurl is an MCP Web Scraper written in Go (with ChromeDriver and Selenium)*

## Introduction

I'm building an LLM chatbot for a specific project. To do this, I need to feed the project's documentation site into an LLM for context (a lightweight RAG workflow). The chatbot's job is to explain how to use the project, the database behind it, and what information is available. I've already created a few MCP tools (with Python's FastAPI-MCP) to expose the database's metadata, but I wasn't able to fully leverage the documentation site.

## Why the detour?

The doc-site authors chose a JS-based documentation generator, which meant a plain `curl` couldn't see any of the content. The documentation only existed after a browser executed the scripts. That experience turned into a broader goal: write an MCP client that could (1) render modern JS-heavy pages, (2) query the open web, and (3) grab binary assets, all exposed through both CLI and MCP transports. It also gave me an excuse to gain more experience building MCP tools in Go. All of my prior MCP work was with FastAPI-MCP in Python, but after vibe-coding an entire LLM chat tool in Python, I wanted something a little more static.

My main workflow looks like this:

``` mermaid
graph LR
  A[Open in headless Chrome] --> B{Extract &lt;body&gt;};
  B --> C[Convert to Markdown];
```

## Prototype

Before moving to Go, I created a proof-of-concept gist to test the workflow (**[Convert a website to Markdown](https://gist.github.com/mbreese/e87e65d1ef99101b22e26761e2e067c1)**). The gist packages ChromeDriver, Selenium, and a Markdown converter into a tiny Docker image so I could spin it up anywhere and yank a fully rendered page into the LLM. I knew I'd eventually need Docker to isolate this stack on a production server, so I mocked it up there first.

```dockerfile
FROM debian:13
RUN apt update && \
    apt install -y chromium-driver python3-pip python3-venv && \
    mkdir /app && \
    cd /app && \
    python3 -m venv venv && \
    venv/bin/pip install selenium markdownify && \
    useradd user

USER user
COPY web_fetch.py /app

CMD /app/venv/bin/python3 /app/web_fetch.py
```

The accompanying script drives headless Chrome, normalizes links, and emits Markdown—perfect for dumping into an MCP session or a prompt file.

```python
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.chrome.options import Options
from markdownify import markdownify as md

service = Service('/usr/bin/chromedriver')
options = Options()
options.add_argument("--no-sandbox")
options.add_argument('--disable-dev-shm-usage')
options.add_argument("--headless=new")

driver = webdriver.Chrome(service=service, options=options)
target_url = sys.argv[1]
if not target_url.startswith(("http://", "https://")):
    target_url = f"http://{target_url}"
driver.get(target_url)
driver.execute_script("""
const links = document.body.querySelectorAll('a');
links.forEach(link => {
    const abshref = link.href;
    link.setAttribute('href', abshref);
});
""")
body = driver.find_element(By.TAG_NAME, "body")
print(md(body.get_attribute("innerHTML")))
driver.quit()
```

Once that setup worked reliably, I rewrote the pieces in Go so I could bundle everything into an MCP server with richer tooling.

> Note: These snippets are pulled directly from the current codebase. They're intentionally out of full context, and I'm omitting most error handling for readability.

## Fetch and Render Dynamic Pages

Everything starts with Selenium's ChromeDriver. Each `WebFetcher` spins up (or connects to) a headless Chrome session, waits for `document.readyState === "complete"`, optionally rewrites relative links to absolute ones, and then converts the captured HTML to Markdown.

The fetcher is configured through an options struct; the most important default is `ChromeDriverPath`, which points at `/usr/bin/chromedriver`.

### Set up the headless browser
```go
    // ...
    caps := selenium.Capabilities{"browserName": "chrome"}
    caps.AddChrome(chrome.Capabilities{Args: []string{
        "--headless",
        "--disable-dev-shm-usage",
        "--disable-gpu",
        "--no-sandbox",
    }})

    wd, err := selenium.NewRemote(caps, fmt.Sprintf("http://localhost:%d/wd/hub", w.opts.WebDriverPort))
    if err != nil {
        service, err := selenium.NewChromeDriverService(w.opts.ChromeDriverPath, w.opts.WebDriverPort)
        if err != nil {
            return fmt.Errorf("error starting ChromeDriver server: %v", err)
        }
        w.service = service
        wd, err = selenium.NewRemote(caps, fmt.Sprintf("http://localhost:%d/wd/hub", w.opts.WebDriverPort))
        if err != nil {
            return fmt.Errorf("failed to open session: %v", err)
        }
    }

    wd.SetPageLoadTimeout(time.Duration(w.opts.PageLoadTimeoutSecs) * time.Second)
    w.wd = wd
    // ...
```

Once the DOM settles, I grab the body, convert relative links when needed, and hand the HTML to whichever Markdown converter fits the deployment.

```go
    // ...
    // Navigate to a URL
    if err := w.wd.Get(targetURL); err != nil {
        fmt.Printf("Error: %v\n\n", err)
        c1 <- tmpResult{nil, fmt.Errorf("failed to load page: %v", err)}
        return
    }

    // Wait for JS to execute or page to load
    w.opts.Logger.Debug("Waiting for page to load")
    err := w.wd.WaitWithTimeout(func(driver selenium.WebDriver) (bool, error) {
        result, err := driver.ExecuteScript("return document.readyState;", nil)
        if err != nil {
            return false, err
        }
        if result == "complete" {
            return true, nil
        }
        return false, nil
    }, time.Duration(w.opts.PageLoadTimeoutSecs)*time.Second)
```

Because the links in the page are likley relative (makes sense...), we should convert them to abolute href's and src values so that the LLM can retrieve other pages as necessary without needing to keep track of what the original web address is.

```go
    // ...
    // if we want to convert Hrefs to absolute paths, run this script
    if w.opts.ConvertAbsoluteHref {
        _, err := w.wd.ExecuteScript(`
const links = document.body.querySelectorAll('a');
const images = document.body.querySelectorAll('img');
links.forEach(link => {
    const abshref = link.href;
    link.setAttribute('href', abshref);
    });
images.forEach(img => {
    const abssrc = img.src;
    img.setAttribute('src', abssrc);
    });
`, nil)
    }
```

Finally, we can extract some information about the page: title, final URL, and importantly, the body.

```go
    // ...
    title, err := w.wd.Title()
    currentURL, err := w.wd.CurrentURL()

    body, err := w.wd.FindElement(selenium.ByTagName, "body")
    htmlSrc, err := body.GetAttribute("innerHTML")

    webpage := &FetchedWebPage{Title: title, TargetURL: targetURL, CurrentURL: currentURL, Src: htmlSrc}
```

I use the `Title`, `CurrentURL`, and `TargetURL` values in the YAML front matter so downstream MCP clients get helpful context about URLs and titles without parsing the body.

## Search the Web Reliably

With that part done, I wanted to add support for quick web searches. For this, I leaned on Google's Custom Search API to avoid building yet another scraper. A thin wrapper turns queries into JSON results, and an optional SQLite cache keeps me from burning API quota on repeat questions.

It's significantly easier to work with than the ChromeDriver/Selenium setup for fetching full pages (and that approach wouldn't work for searching Google anyway).

```go
    if w.cache != nil {
        if results, ok, err := w.cache.Get(ctx, query); err == nil && ok {
            return results, nil
        }
    }

    results, err := w.search.SearchJSON(ctx, query)
    if err != nil {
        return nil, err
    }

    if w.cache != nil {
        if err := w.cache.Put(ctx, query, results); err != nil {
            w.opts.Logger.Warn("search cache put failed", "error", err)
        }
    }
```

The searcher itself is little more than a strongly typed HTTP client I can point at Google or any other engine that implements the same interface. I tried to keep the search code generic enough where I could plug in other search engines in the future (SearXNG, for example).

```go
    urlQuery := fmt.Sprintf("%s?%s=%s", s.config.URL, s.config.Params["queryKey"], url.QueryEscape(query))

    // s.config.Params contains the cx and key values necessary for Google Custom Search API calls
    for k, v := range s.config.Params {
        urlQuery += fmt.Sprintf("&%s=%s", url.QueryEscape(k), url.QueryEscape(v))
    }

    req, err := http.NewRequestWithContext(ctx, http.MethodGet, urlQuery, nil)
    // ...
    if resp.StatusCode < 200 || resp.StatusCode >= 300 {
        return nil, fmt.Errorf("api status: %s", resp.Status)
    }

    var results []SearchResult
    if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
        return nil, err
    }
```

Finally, I added an SQLite cache layer (compiled with CGO) to keep track of search results. I expect limited search traffic, and I want to minimize costs as much as possible.

## Strech Goal: Download Binary Assets

Sometimes the model may need an image or PDF referenced in the page. The download path streams the resource with configurable byte limits, enforces status-code checks, and hands back filename, content type, and base64 data.

```go
    req, err := http.NewRequestWithContext(ctx, http.MethodGet, targetURL, nil)
    if err != nil {
        return nil, fmt.Errorf("error building request: %w", err)
    }

    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        return nil, fmt.Errorf("error downloading %s: %w", targetURL, err)
    }
    defer resp.Body.Close()

    if resp.StatusCode < 200 || resp.StatusCode >= 300 {
        return nil, fmt.Errorf("unexpected status code %d downloading %s", resp.StatusCode, targetURL)
    }

    limit := w.opts.MaxDownloadBytes
    body, err := io.ReadAll(io.LimitReader(resp.Body, int64(limit)+1))
    if len(body) > limit {
        return nil, fmt.Errorf("resource exceeds %d bytes limit", limit)
    }

    filename := path.Base(resp.Request.URL.Path)
    if filename == "/" || filename == "." {
        filename = ""
    }

    return &DownloadedResource{
        Filename:    filename,
        ContentType: resp.Header.Get("Content-Type"),
        Body:        body,
    }, nil
```

In CLI mode, `mcpfurl fetch-img` simply writes `resource.Body` to disk; in MCP mode the tool base64-encodes the bytes so agents can stash them wherever they like.

```go
	return nil, &ImageFetchOutput{
		Filename:    resource.Filename,
		ContentType: resource.ContentType,
		DataBase64:  base64.StdEncoding.EncodeToString(resource.Body),
    }
```

## Security

To make the MCP HTTP-streaming server a bit more secure, I added a simple bearer-token authentication mechanism. At the moment there's a single optional `MCPFURL_MASTERKEY`. If that variable is set and the incoming request includes the same value in the `Authorization` header, the request is allowed. In practice, I'm currently running without `MCPFURL_MASTERKEY` behind a LiteLLM proxy, which handles authorization for me.

I'm planning to add support for additional delegate client keys in the future.

## Summary
To make testing easier, I wired everything up as CLI commands first and exposed the MCP tools later. That workflow let me iterate quickly without exercising the entire MCP stack on every change.

This article touches on the highlights but skips some specifics, such as running fetches in goroutines, coordinating access with locks, using contexts with libraries that aren't context-aware, and threading config through files or CLI flags.

Ultimately, I think the foundation is solid: fetch anything, summarize it cleanly, and hand it to whatever agent needs it.

### Takeaways

- Headless Chrome plus Markdown conversion keeps the output readable for LLMs while faithfully capturing script-generated DOMs.
- Google Custom Search with caching gives me high-signal search snippets without hammering APIs.
- With CLI, MCP stdio, and MCP HTTP modes, I can deploy the same binary in multiple places.

### Downsides

- I still haven't figured out how to run the Go Selenium driver as a non-root user inside the Docker container. It works without root in the Python gist, so I suspect my Go setup is missing a flag or two.
- I'm using CGO to include SQLite for the cache, which makes cross-architecture builds painful. GitHub Actions handles it for now, but I may switch to the pure-Go driver.
- The Go Selenium library I'm using hasn't been updated in ages. It's functional, but the Python version moves faster. One workaround might be to pre-start the WebDriver as the non-root user before launching the Go code—or just stick with Python.
- The current design fetches only one page at a time because WebDriver interactions are locked behind a mutex. Scaling would require spinning up multiple drivers and managing them in a pool, which feels like overkill for now.

### Next Steps

- Swap in additional search engines
- Add parallel fetchers for higher throughput
- Improve API-token security
- Enforce URL allow/deny lists

### Repository

GitHub: http://github.com/mbreese/mcpfurl
