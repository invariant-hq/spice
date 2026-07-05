Web tools are opt-in host tools. Fetch is registered by config alone; search
requires both the Brave backend kind and the environment-provided API key.

  $ spice debug tools | grep '^## web_'
  [1]

  $ spice config set web.enabled true
  $ spice debug tools | grep '^## web_'
  ## web_fetch

  $ spice config set web.search_backend brave
  $ spice debug tools | grep '^## web_'
  ## web_fetch

  $ SPICE_WEB_BRAVE_API_KEY=secret spice debug tools | grep '^## web_'
  ## web_fetch
  ## web_search

Configuration values are visible, but the Brave API key is not a config value.

  $ spice config get web.enabled
  true
  $ spice config get web.search_backend
  brave
  $ SPICE_WEB_BRAVE_API_KEY=secret spice config show 2>&1 | grep -c secret
  0
  [1]
