Fetch content from one public HTTP or HTTPS URL.

Use this tool when you need to retrieve and inspect a specific public web page.
Use a specialized authenticated tool instead for private or authenticated URLs
such as Google Docs, Confluence, Jira, GitHub private resources, cloud consoles,
or MCP connectors. For GitHub repositories, issues, and pull requests, prefer
the gh CLI through the shell when it is available — it returns structured data
where the web page returns chrome.

The tool is read-only. HTML is returned as markdown by default. Host policy may
upgrade HTTP URLs to HTTPS before fetching. Cross-host redirects are reported
instead of followed automatically; make a new request for the redirect target
when appropriate. Large outputs may be truncated with an omitted-character count.
