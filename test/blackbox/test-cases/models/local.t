Local models carry memory-fit verdicts. The suite pins a 24 GiB budget
(SPICE_LOCAL_MEMORY_BUDGET in the setup script) so verdicts do not depend on
the machine running the tests; hosted models show no verdict.

  $ git init -q

  $ spice models --provider local
  MODEL                    STATUS  CONTEXT  COST $/MTOK  FIT
  local/qwen3-coder-30b *  stable  262144   -            fits (~21.9 GiB of 24.0 GiB)
  local/gpt-oss-20b        stable  131072   -            fits (~14.4 GiB of 24.0 GiB)
  local/devstral-small-2   stable  393216   -            fits (~20.0 GiB of 24.0 GiB)
  local/qwen3.6-35b        stable  262144   -            fits (~22.9 GiB of 24.0 GiB)
  * provider default

A tighter budget degrades verdicts honestly: models that still fit say so,
models that fit only at a reduced context report that ceiling, and models
whose weights alone exceed the budget report what they would need.

  $ SPICE_LOCAL_MEMORY_BUDGET=22548578304 spice models --provider local
  MODEL                    STATUS  CONTEXT  COST $/MTOK  FIT
  local/qwen3-coder-30b *  stable  262144   -            fits up to ~22k context
  local/gpt-oss-20b        stable  131072   -            fits (~14.4 GiB of 21.0 GiB)
  local/devstral-small-2   stable  393216   -            fits (~20.0 GiB of 21.0 GiB)
  local/qwen3.6-35b        stable  262144   -            needs ~22.4 GiB, 21.0 GiB usable
  * provider default

  $ SPICE_LOCAL_MEMORY_BUDGET=8589934592 spice models --provider local
  MODEL                    STATUS  CONTEXT  COST $/MTOK  FIT
  local/qwen3-coder-30b *  stable  262144   -            needs ~19.7 GiB, 8.0 GiB usable
  local/gpt-oss-20b        stable  131072   -            needs ~13.3 GiB, 8.0 GiB usable
  local/devstral-small-2   stable  393216   -            needs ~16.2 GiB, 8.0 GiB usable
  local/qwen3.6-35b        stable  262144   -            needs ~22.4 GiB, 8.0 GiB usable
  * provider default

The verdict is data in JSON, not prose.

  $ spice models show local/gpt-oss-20b --json | grep -o '"fit":{"verdict":"[a-z_]*"'
  "fit":{"verdict":"fits"

  $ SPICE_LOCAL_MEMORY_BUDGET=8589934592 spice models show local/gpt-oss-20b --json | grep -o '"verdict":"[a-z_]*"'
  "verdict":"wont_run"

Hosted models carry a null fit.

  $ spice models show openai/gpt-5.5 --json | grep -o '"fit":null'
  "fit":null

Model detail shows the same verdict line.

  $ spice models show local/qwen3-coder-30b | grep '^fit'
  fit                  fits (~21.9 GiB of 24.0 GiB)

Explicit GGUF paths resolve as dynamic models under the local provider: the
selector is the path, the display name is the file, and only the tools
capability is assumed. Resolution is pure — the file need not exist until a
request runs — and non-GGUF ids still fail as unknown models.

  $ spice models show "local/$PWD/tiny.gguf" | grep -E '^(display_name|api|capabilities)'
  display_name         tiny.gguf
  api                  chat-completions
  capabilities         json_schema, tools

  $ spice models show local/not-a-model >stdout 2>stderr; code=$?; cat stderr; echo "code=$code"
  spice: unknown model "not-a-model" for provider "local"
  code=2

Downloads are guarded: a model this machine cannot run is refused before
any bytes move, with the override spelled out. Hosted models are not
downloadable, and an installed artifact short-circuits.

  $ SPICE_LOCAL_MEMORY_BUDGET=8589934592 spice models download local/gpt-oss-20b >stdout 2>stderr; code=$?; cat stderr; echo "code=$code"
  spice: local model "gpt-oss-20b" needs an estimated 13.3 GiB of memory even at a 8192-token context; this machine's usable budget is 8.0 GiB. It would download (11.3 GiB) but never load. Override the guard to download anyway. (--force overrides the guard)
  code=1

  $ spice models download openai/gpt-5.5 >stdout 2>stderr; code=$?; cat stderr; echo "code=$code"
  spice: models download fetches local weights; "openai" is a hosted provider
  code=2

  $ mkdir -p "$XDG_DATA_HOME/spice/models"
  $ touch "$XDG_DATA_HOME/spice/models/gpt-oss-20b-mxfp4.gguf"
  $ spice models download local/gpt-oss-20b
  already installed: $TESTCASE_ROOT/xdg-data/spice/models/gpt-oss-20b-mxfp4.gguf
  $ rm "$XDG_DATA_HOME/spice/models/gpt-oss-20b-mxfp4.gguf"
