Extra config files are loaded from [SPICE_CONFIG].

  $ git init -q

User config is lower precedence than the extra config file.

  $ spice config set model openai/gpt-5.5
  $ cat > extra.json <<EOF
  > {"model":"openai/extra-model"}
  > EOF

  $ SPICE_CONFIG=extra.json spice config get model
  openai/extra-model

Malformed extra config files fail effective validation.

  $ printf '[' > bad-extra.json
  $ SPICE_CONFIG=bad-extra.json spice config validate
  spice: $TESTCASE_ROOT/bad-extra.json: Expected JSON value but found end of text
  File "-", line 1, characters 1-2:
  File "-", line 1, characters 1-2: at index 0 of
  File "-", line 1, characters 0-2: array<json>
  [1]
